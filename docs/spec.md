# codex TUI patch set — spec

Scope: two additions to the patch we already ship for codex `0.146.0`.

- **A.** `/fast on` and `/fast off`, alongside the existing bare `/fast` toggle.
- **B.** Remove a fixed set of slash commands, for predictability inside Minds.

All line numbers are against tag `rust-v0.146.0`.

---

## A. `/fast on` / `/fast off`

### What `/fast` actually is

It is **not** a `SlashCommand` enum variant. There is no `Fast` in
`tui/src/slash_command.rs`. It is a *dynamic* command built at runtime from the
model catalog:

```
model_catalog → preset.service_tiers → ServiceTierCommand { id, name, description }
                                       name = tier.name.to_lowercase()   // "fast"
```

`tui/src/chatwidget/service_tiers.rs:82` (`current_model_service_tier_commands`)

Consequences worth knowing before touching it:

- The string `"fast"` comes from the **server-side catalog**, not our source. If
  the catalog renames the tier, the command renames itself.
- It only appears when `Feature::FastMode` is on (`[features] fast_mode`,
  default `true`) **and** the current model advertises that tier. `/fast` does
  not exist on models without it.
- Whatever we build generalizes to every tier for free — `/flex on` works the
  same way, because nothing in the change is `fast`-specific.

### Current behaviour

Bare `/fast` dispatches to `toggle_service_tier_from_ui`
(`service_tiers.rs:66`), which flips between `command.id` and
`SERVICE_TIER_DEFAULT_REQUEST_VALUE`, then calls the single apply path:

```rust
fn set_service_tier_selection(&mut self, service_tier: Option<String>) {
    self.set_service_tier(service_tier.clone());
    self.app_event_tx.send(AppEvent::CodexOp(AppCommand::override_turn_context(..., Some(service_tier.clone()), ...)));
    self.app_event_tx.send(AppEvent::PersistServiceTierSelection { service_tier });
}
```

`/fast on` today is **the same bug as `/model gpt-5.4 high`**: it is not
recognised as taking arguments, so the whole line is submitted to the model as
chat and the model plays along. Same silent failure, same root cause.

### Three barriers, all explicit

1. `bottom_pane/slash_commands.rs:37` — `SlashCommandItem::supports_inline_args()`
   returns a hard-coded `false` for `ServiceTier`.
2. `bottom_pane/chat_composer.rs:3172` — `try_dispatch_slash_command_with_args`
   bails: `let SlashCommandItem::Builtin(cmd) = command else { return None };`
3. `InputResult::CommandWithArgs(SlashCommand, String, Vec<TextElement>)` is
   typed to builtins only, so there is no variant that can carry a
   `ServiceTierCommand` plus args.

### Changes

**1. `bottom_pane/slash_commands.rs`** — allow inline args on service tiers:

```rust
pub(crate) fn supports_inline_args(&self) -> bool {
    match self {
        Self::Builtin(cmd) => cmd.supports_inline_args(),
        Self::ServiceTier(_) => true,
    }
}
```

**2. `bottom_pane/chat_composer.rs`** — add an `InputResult` variant rather than
widening `CommandWithArgs`:

```rust
/// A model service-tier command and its trimmed argument text.
ServiceTierCommandWithArgs(ServiceTierCommand, String),
```

Widening `CommandWithArgs`'s first field to `SlashCommandItem` was the
alternative. Rejected: it forces every existing arm to re-handle a case that
cannot occur there, and touches ~10 test sites for no behavioural gain. A new
variant leaves existing arms untouched.

No `Vec<TextElement>` on the variant. Args here are `on`/`off` — there are no
file mentions or pastes to rebase.

Then in `try_dispatch_slash_command_with_args`, replace the bail:

```rust
let cmd = match command {
    SlashCommandItem::Builtin(cmd) => cmd,
    SlashCommandItem::ServiceTier(command) => {
        return Some(InputResult::ServiceTierCommandWithArgs(
            command,
            trimmed_rest.to_string(),
        ));
    }
};
```

**3. `chatwidget/input_flow.rs:65`** — handle the new variant next to the
existing `InputResult::ServiceTierCommand` arm, calling the new dispatch below.

**4. `chatwidget/slash_dispatch.rs:989`** — the queued-input drain path has its
own copy of the builtin-only bail. Route service tiers there too, otherwise
`/fast on` behaves differently when queued during a running turn than when typed
idle. Keep the existing side-conversation guard from
`handle_service_tier_command_dispatch` first.

**5. `chatwidget/service_tiers.rs`** — the actual handler:

```rust
pub(crate) fn set_service_tier_from_args(&mut self, command: ServiceTierCommand, args: &str) {
    let next_tier = match args.trim().to_ascii_lowercase().as_str() {
        "on"  => Some(command.id),
        "off" => Some(SERVICE_TIER_DEFAULT_REQUEST_VALUE.to_string()),
        other => {
            self.add_error_message(format!(
                "'/{} {other}' is not valid. Use '/{0} on' or '/{0} off', or '/{0}' to toggle.",
                command.name
            ));
            return;
        }
    };
    self.set_service_tier_selection(next_tier);
}
```

It calls `set_service_tier_selection` — **the same private apply path the toggle
uses**. Same principle as the `/model` patch: route into the existing apply
function rather than replicate what it does downstream, so config update,
`override_turn_context`, and persistence stay in one place.

### Resulting behaviour

| input | result |
|---|---|
| `/fast` | toggle — unchanged |
| `/fast on` | force the fast tier; idempotent |
| `/fast off` | force the default tier; idempotent |
| `/fast maybe` | error naming the valid values; nothing applied |
| `/flex on` | works identically — nothing is `fast`-specific |

### Known gap

The keybinding at `tui/src/app/input.rs:165` calls `toggle_fast_mode_from_ui()`
directly and still toggles. `/fast on` does not make the state un-toggleable, it
only makes the *command* deterministic. Removing the keybinding is a separate
decision — say so if you want it in scope.

---

## B. Command lockdown

### One choke point

Both the popup and typed dispatch flow through `builtins_for_input()`
(`bottom_pane/slash_commands.rs:69`):

- popup: `commands_for_input()` calls it
- typed: `find_builtin_command()` calls it and requires membership
  (`slash_commands.rs:118-125`)

So **one filter line disables both**. A blocked command typed by hand produces
the existing `Unrecognized command '/new'. Type "/" for a list of supported
commands.` No new error path needed.

### Requested list

All twelve exist as enum variants, so all twelve are blockable:

`New` `Archive` `Delete` `Keymap` `Vim` `Experimental` `Fork` `Side` `Exit`
`Clear` `Agent` `Plan`

### Three gaps in that list

Each of these is a *separate enum variant* that reaches the same behaviour, so
blocking only the name you listed leaves a working back door:

| you blocked | still open | evidence |
|---|---|---|
| `/exit` | **`/quit`** | `SlashCommand::Quit \| SlashCommand::Exit => "exit Codex"` (`slash_command.rs:97`) |
| `/side` | **`/btw`** | `SlashCommand::Side \| SlashCommand::Btw => "start a side conversation in an ephemeral fork"` (`:124`) |
| `/agent` | **`/subagents`** | `SlashCommand::Agent \| SlashCommand::MultiAgents => "switch the active agent thread"` (`:123`) |

Recommend blocking all three. Otherwise the lockdown is cosmetic for those.

### Also worth considering

Not in your list, same predictability rationale:

- **`/resume`** — switches to a different saved chat. Same class as `/new`; the
  strongest candidate to add.
- `/compact` — mutates the transcript under the harness.
- `/logout` — breaks auth mid-session.

My recommendation: add `/resume`, leave `/compact` and `/logout`. Your call.

### Not a security boundary

`Ctrl-C` / `Ctrl-D` still exit the TUI. Removing `/exit` makes the command
surface predictable; it does not contain anything. Worth stating so nobody
later mistakes it for a sandbox.

### Mechanism

**Recommended — hard-coded list, one filter:**

```rust
/// Commands hidden in Minds: each one starts, switches, or destroys a session,
/// or changes input handling, in ways the harness cannot observe.
const BLOCKED: &[SlashCommand] = &[
    SlashCommand::New, SlashCommand::Clear, SlashCommand::Fork,
    SlashCommand::Archive, SlashCommand::Delete, SlashCommand::Resume,
    SlashCommand::Side, SlashCommand::Btw,
    SlashCommand::Agent, SlashCommand::MultiAgents,
    SlashCommand::Exit, SlashCommand::Quit,
    SlashCommand::Keymap, SlashCommand::Vim,
    SlashCommand::Experimental, SlashCommand::Plan,
];
```

added to `builtins_for_input` as `.filter(|(_, cmd)| !BLOCKED.contains(cmd))`.

**Alternative — config-driven** `[tui] disabled_slash_commands = ["new", ...]`,
which would let dwt change policy without a rebuild. More plumbing:
`BuiltinCommandFlags` is `Copy`, so it cannot hold a `Vec` and would need a
bitset or a separate parameter threaded through every call site.

Take the hard-coded list. We rebuild the binary per codex version anyway, so the
config indirection buys nothing today. Revisit only if policy needs to differ
between workspaces.

### One command needs no patch

`/plan` is already gated by `Feature::CollaborationModes`
(`slash_commands.rs:73`), config key `collaboration_modes`. But its spec is
`stage: Stage::Removed, default_enabled: true` — a flag on the way out, and
removed-stage flags are not reliably honoured. Block it in the list with the
rest rather than depending on a feature flag that upstream is deleting.

---

## Tests

Extend `tui/src/chatwidget/tests/slash_commands.rs`, which already holds the two
`/model` tests.

1. `fast_on_sets_fast_tier` — assert `PersistServiceTierSelection` carries the
   tier id and `config.service_tier` matches.
2. `fast_off_sets_default_tier` — assert it carries
   `SERVICE_TIER_DEFAULT_REQUEST_VALUE`.
3. `fast_on_is_idempotent` — run twice, assert still on. Guards against
   accidentally re-introducing toggle semantics.
4. `fast_with_bad_arg_changes_nothing` — assert no `PersistServiceTierSelection`.
5. `blocked_commands_are_not_found` — `find_builtin_command(name, flags)` is
   `None` for every entry in `BLOCKED`.
6. `allowed_commands_still_resolve` — `model`, `status`, `diff` still `Some`.
   Without this a filter bug that blocks everything passes test 5.

`build.sh` already runs `cargo test -p codex-tui --lib slash_model` before it
will produce a binary. Widen that filter to cover the new tests — name them so
one filter catches both, or change the command to run the whole
`chatwidget::tests::slash_commands` module.

---

## Packaging

- **One patch file per version.** `build.sh` applies exactly one
  `patches/<version>.patch`, so these changes extend
  `patches/0.146.0.patch` rather than adding a second file. One patch, one
  binary.
- **The repo name is now wrong.** `codex-slash-model` describes the first patch,
  not a patch set. Rename to something like `codex-minds-patches` before this
  lands and gets referenced from dwt — cheap now, annoying later. `gh repo
  rename` keeps redirects working, but the dwt URL should be updated anyway.
- **Release tag** moves from `v0.146.0` to something version-scoped
  rather than feature-scoped, e.g. `v0.146.0-minds.2`, since the contents will
  keep growing.
- Blast radius stays small: still `tui` only, still no V8, so build time and
  binary size are unchanged.

---

## Effort

| | |
|---|---|
| B, lockdown | ~20 lines and 2 tests. Trivial — one filter at one choke point. |
| A, `/fast on\|off` | ~90 lines across 5 files and 4 tests. Larger than the `/model` patch because it needs a new `InputResult` variant threaded through two dispatch paths. |

Both are mechanical once the choke points above are accepted. The uncertainty is
not in the code, it is in whether the blocked list is the right list.

## Open questions

1. Block `/quit`, `/btw`, `/subagents` too? (Recommend yes — otherwise the
   lockdown is cosmetic for exit, side, and agent.)
2. Block `/resume`? (Recommend yes.)
3. Should the `Ctrl` fast-mode keybinding be removed alongside `/fast on|off`?
   (Recommend leaving it; it is discoverable and reversible.)
