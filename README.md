# codex-in-minds

Patches to the [codex](https://github.com/openai/codex) CLI for running it inside
[Minds](https://imbue.com), plus a one-command script that builds the patched
binaries on throwaway EC2 boxes.

Two goals, and everything here serves one or the other:

1. **Give the harness commands it can drive.** Settings changes should be one
   deterministic line, not a keyboard walk through an interactive picker.
2. **Stop the chat flow from being reshaped underneath the harness.** Minds
   watches a session's transcript; commands that silently start, switch, or
   destroy a thread make that view wrong.

## What the patch does

**1. `/model <model> [effort]`** — set model and reasoning effort in one line.

```
/model gpt-5.4 high
• Model changed to gpt-5.4 high
```

Upstream, `/model` with arguments is a silent no-op that looks like it worked:
the args are sent to the model as chat and it replies *"Using gpt-5.4 with high
reasoning"* — a string that appears nowhere in the codex source — while the
status line still shows the old model. Upstream issue:
[openai/codex#32212](https://github.com/openai/codex/issues/32212).

**2. `/fast on` and `/fast off`** — set the service tier explicitly.

| input | result |
|---|---|
| `/fast` | toggle — unchanged |
| `/fast on` | force the fast tier; repeating it is a no-op, not a flip back |
| `/fast off` | force the default tier |
| `/fast maybe` | error naming the valid values; nothing applied |

`/fast` is not a built-in command in codex — it is generated at runtime from the
model catalog the server sends. So this works for any tier the catalog offers:
`/flex on` behaves identically, and nothing in the change is `fast`-specific.

Before this, `/fast on` failed the same way `/model gpt-5.4 high` did.

**3. Session-reshaping commands are withheld.**

`/new` `/clear` `/fork` `/archive` `/delete` `/resume` `/side` `/btw` `/agent`
`/subagents` `/exit` `/quit` `/keymap` `/vim` `/experimental` `/plan`

Each either starts, switches, or destroys a thread, or changes how the composer
reads input. Minds follows a session by reading its transcript, so a command
that swaps the thread out from under it leaves that view describing a
conversation the user is no longer in.

Aliases are blocked alongside their primaries — `/quit` with `/exit`, `/btw`
with `/side`, `/subagents` with `/agent` — because each is a separate enum
variant and blocking one leaves the other reachable.

> This is a predictability measure, **not a containment boundary.** `Ctrl-C` and
> `Ctrl-D` still exit the TUI.

Blocked commands are hidden from the `/` popup and, if typed in full, produce
the stock `Unrecognized command` message. Both go through one filter, because
the popup and typed dispatch share a single choke point.

**4. Queued input is recorded the instant it is queued.**

Submit while a turn is running and codex holds the message in memory only. It
reaches the transcript when the running turn finally ends, so until then nothing
outside the process can tell an accepted message from a dropped one. Minds shows
an optimistic bubble on send and flips it to "Queued" once the backend confirms
acceptance -- but codex's confirmation comes from the `active` marker, set by the
UserPromptSubmit hook, which by definition does not fire for a message that was
queued rather than started.

Each queued message now appends one line to `$CODEX_HOME/queued_input.jsonl`:

```json
{"type":"queued_input","queued_id":"...","thread_id":"...","timestamp":"...","content":"..."}
```

codex's queue itself is untouched -- ordering, draining and the slash-command
paths all behave exactly as before. This only observes the branch that was
already there.

`queued_id` is a correlation id. Claude Code's equivalent records omit one and
leave readers matching on message text, which is brittle enough that the Minds
frontend carries a FIXME asking for exactly this.

> **Why a sidecar and not the rollout.** The rollout JSONL is written by core,
> and the TUI reaches core through the in-process app-server -- appending a
> rollout item from the TUI needs a new protocol request, a processor and a core
> handler across four crates. The trade-off is that these records are not part of
> the durable session and do not survive `codex resume`. That is fine: they
> answer "was this accepted, right now", and the message still lands in the
> rollout as a normal user turn once it is sent.

Design notes and the source-level reasoning are in **[docs/spec.md](docs/spec.md)**
and **[docs/spec-queued-transcript.md](docs/spec-queued-transcript.md)**.

---

## 1. Build the binaries

```sh
git clone https://github.com/minhtrinh-imbue/codex-in-minds
cd codex-in-minds
./build.sh --version 0.146.0
```

That is the whole thing. Roughly 15 minutes, a few dollars of EC2, and it
leaves three files in the directory you ran it from:

```
codex-linux-arm64
codex-linux-amd64
SHA256SUMS
```

What it does, in order: clones codex at tag `rust-v0.146.0`, applies
`patches/0.146.0.patch`, launches one EC2 builder per architecture, builds
**natively** on each (no cross-compilation, no qemu), runs the tests, smoke-runs
`codex --version` on the matching arch, pulls the binaries back, and terminates
everything.

**Prerequisites:** an authenticated `aws` cli, plus `ssh`/`scp`/`curl`. No local
Rust, no local Docker — that is the point. It runs fine from a Mac and does not
load your laptop.

| flag | |
|---|---|
| `--version X.Y.Z` | required; needs a matching `patches/X.Y.Z.patch` |
| `--arch arm64` or `--arch amd64` | build just one |
| `--keep` | leave the builders up to debug a failure |

**It will sit still near the end.** codex's release profile uses thin LTO across
~1000 crates, so the crate counter stops moving for several minutes during the
final link. That is not a hang.

**It always terminates.** Success, error, or Ctrl-C — the `trap` fires on every
path. `--keep` is the only way to leave instances running, and it prints the
terminate command when it does. Two `c7*.4xlarge` are about $1.30/hour.

---

## 2. Cut a release

```sh
gh release create v0.146.0 \
  codex-linux-arm64 codex-linux-amd64 SHA256SUMS \
  --title "codex 0.146.0 for Minds" \
  --notes "Patched codex 0.146.0: inline /model and /fast args, session-reshaping commands withheld."
```

> **This repo must stay public.** A workspace build `curl`s the release asset
> with no credentials, so flipping it private breaks image builds with a 404.

---

## 3. Install it into the workspace (dwt)

Two edits to `system/scripts/setup_system.sh`, against the `harnesses-dwt`
branch.

**Edit 1** — add a pin beside the others (the `CODEX_VERSION` line is ~line 39):

```sh
: "${CODEX_VERSION:=0.146.0}"
: "${CODEX_PATCH_RELEASE:=v0.146.0}"
```

**Edit 2** — paste this immediately after the existing codex install
(`npm install -g "@openai/codex@${CODEX_VERSION}"` / `command -v codex`,
~line 236):

```sh
# Replace the binary npm just vendored with a patched build that supports
# `/model <model> [effort]`; upstream makes that a silent no-op that looks like
# it worked (openai/codex#32212). npm still performs the install above -- we
# overwrite exactly one file inside it. The codex-code-mode-host binary beside
# it embeds V8 and is left alone, which is what keeps this patch cheap to carry.
codex_patch_arch="$(dpkg --print-architecture)"
case "${codex_patch_arch}" in
    arm64) codex_patch_sha256="bf66315aff29b547b239305394d2586e8f3489fb69384926294ac3118621533e" ;;
    amd64) codex_patch_sha256="487284a431fbbf91a4be5fbf99e314d840a18243883703032954c6e7871a8a37" ;;
    *) echo "Unsupported architecture for patched codex: ${codex_patch_arch}" >&2; exit 1 ;;
esac
# npm nests the platform subpackage, and the exact path differs between npm
# versions, so locate it rather than hardcoding it. Refuse ambiguity instead of
# picking one and patching the wrong install.
codex_vendored="$(find /usr/local/lib/node_modules/@openai -type f -path '*/vendor/*/bin/codex')"
if [ "$(printf '%s\n' "${codex_vendored}" | grep -c .)" != "1" ]; then
    echo "Expected exactly one vendored codex binary, found: ${codex_vendored:-none}" >&2
    exit 1
fi
# Same download-then-rename(2) dance as install_downloaded_binary (see its
# comment re: ETXTBSY on a live re-provision), with a checksum in the middle.
codex_patch_tmp="$(mktemp "${codex_vendored}.XXXXXX")"
curl -fsSL "https://github.com/minhtrinh-imbue/codex-in-minds/releases/download/${CODEX_PATCH_RELEASE}/codex-linux-${codex_patch_arch}" -o "${codex_patch_tmp}"
echo "${codex_patch_sha256}  ${codex_patch_tmp}" | sha256sum -c -
chmod 0755 "${codex_patch_tmp}"
mv -f "${codex_patch_tmp}" "${codex_vendored}"
codex --version
```

The two sums above are the ones in the `v0.146.0` release. If you cut a
new release, replace them with the values from that build's `SHA256SUMS` — the
binaries are not byte-reproducible across builds.

Three notes on why it is shaped this way:

- **It does not call `install_downloaded_binary`.** That helper fetches straight
  from a URL with no checksum, and every other download in this file is
  sha256-verified. The block above reproduces the helper's atomic
  download-to-temp-then-`mv` (which is what avoids `ETXTBSY` when re-provisioning
  a live workspace) and adds the verification step.
- **`dpkg --print-architecture` prints `arm64`/`amd64`**, which is exactly how the
  release assets are named. No translation table.
- **`codex --version` at the end** reports `0.146.0`, not `0.0.0`, because the
  build uses the release tag rather than main. So this doubles as a check that
  the right binary landed, and the pin stays consistent with
  `agent_types.codex.version` in `.mngr/settings.toml`.

---

## The bug this fixes

`/model gpt-5.6-terra max` today does not fail — it does nothing, and looks like
it worked.

`SlashCommand::Model` is not in `supports_inline_args()`, so the dispatcher falls
through to `submit_user_message` and the whole line is sent to the model **as
chat**. The model replies *"Using gpt-5.6-terra with maximum reasoning."* — a
string that appears nowhere in the codex source — while the status line correctly
still shows the old model. The acknowledgement is the LLM playing along, not the
CLI confirming.

## What the patch does

Three files, ~100 lines added, no existing lines changed:

| file | change |
|---|---|
| `tui/src/slash_command.rs` | add `Model` to `supports_inline_args()` |
| `tui/src/chatwidget/slash_dispatch.rs` | route `/model` args to the handler |
| `tui/src/chatwidget/model_popups.rs` | the handler |

The handler resolves the preset from the same catalog the picker reads, then
invokes **the same `SelectionAction` the picker builds**. It is not a
reimplementation — the Ultra and plan-mode-scope branches come along for free,
because they live inside the function being called.

| input | behaviour |
|---|---|
| `/model` | picker opens, unchanged |
| `/model gpt-5.4 high` | both applied immediately |
| `/model gpt-5.4` | model applied at its default effort |
| `/model gpt-5.4 ultra` | error listing the efforts that model supports |
| `/model nonsense high` | error listing available models |

## Verification

Every build runs `cargo test -p codex-tui --lib minds_` and refuses to produce a
binary if it fails. Thirteen tests, all added by the patch:

| test | guards |
|---|---|
| `minds_slash_model_with_inline_args_applies_model_and_effort` | `UpdateModel` **and** `UpdateReasoningEffort` are emitted |
| `minds_slash_model_with_unknown_model_reports_error_and_applies_nothing` | a typo cannot silently apply nothing |
| `minds_slash_fast_on_selects_the_fast_tier` | `/fast on` persists the fast tier |
| `minds_slash_fast_off_selects_the_default_tier` | `/fast off` persists the default tier |
| `minds_slash_fast_on_is_idempotent` | repeating `/fast on` stays on rather than toggling off |
| `minds_slash_fast_with_bad_arg_changes_nothing` | a bad argument applies nothing |
| `minds_blocked_commands_do_not_resolve` | every blocked command fails lookup |
| `minds_blocked_command_aliases_do_not_resolve` | `/quit`, `/btw`, `/subagents` are blocked too |
| `minds_allowed_commands_still_resolve` | `/model`, `/status`, `/diff`, `/compact`, `/review` still work — without this, a filter bug that hides *everything* would pass the two tests above |
| `minds_queued_input_record_is_one_json_line` | the record is a single parseable line |
| `minds_queued_input_record_escapes_newlines_in_content` | a newline in the message cannot forge a second record |
| `minds_append_queued_input_appends_rather_than_truncates` | a second queued message does not clobber the first, and ids are distinct |
| `minds_append_queued_input_survives_an_unwritable_directory` | a failed write never stops the message being queued |

### Known-red upstream tests

The patch deliberately removes commands that upstream tests assert are
reachable, so `cargo test -p codex-tui --lib` (the *whole* suite) is not green.
Measured on this patch, in a debug build with `RUST_MIN_STACK=33554432`:

| | failures |
|---|---|
| pristine `rust-v0.146.0` | 22 — environment-dependent `status::` and `history_cell::` snapshots, nothing to do with us |
| with this patch | 48 |

The 26 added failures are all lockdown tests — `slash_popup_side_for_si_ui`,
`slash_new_with_name_requests_named_session`, `plan_command_visible_...`, and
so on. Every one asserts that a command we removed is reachable. They are not
rewritten to assert the opposite, because that is a large diff testing removed
behaviour that would re-conflict on every codex version bump.

Two things worth knowing about that measurement:

- **A stack overflow in `fork_current_session_preserves_conversation_ultra` is
  pre-existing.** It reproduces on unpatched `rust-v0.146.0` and aborts the
  whole test binary. Raising `RUST_MIN_STACK` is what makes a full-suite run
  possible at all; it is a debug-build frame-size issue, not a code bug.
- **One test was genuinely changed, not just broken.**
  `slash_completion_does_not_preserve_existing_draft_tail_for_other_commands`
  used `/model` as its example of a command taking no arguments. `/model` takes
  arguments now, so preserving a typed tail as args is correct for it — the
  same behaviour `/review` already had. The test was repointed at `/diff`,
  which still takes none.

Confirmed green on 0.146.0 on both arches, and the arm64 binary was driven live
in a real workspace: the status line went `gpt-5.5 xhigh` → `gpt-5.4 high`.

## Caveat

**Patches are per-version.** `patches/0.146.0.patch` is verified against that tag
and nothing else. A new codex release needs its own patch file — usually a
straight copy, since the touched code is stable, but it needs `git apply --check`
against the new tag rather than an assumption.

## Layout

```
build.sh              the only script; --version is the only required flag
patches/0.146.0.patch code + tests, verified against tag rust-v0.146.0
```

The binaries are glibc, built on `rust:1-trixie`, matching the
`python:3.12-slim-trixie` workspace base image. npm's vendor directory is named
`...-musl`; that is just a path, and a glibc binary runs there fine.
