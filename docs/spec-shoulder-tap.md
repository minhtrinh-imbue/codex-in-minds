# Shoulder tap — semantic spec and implementation guide

How Minds should render a message the user types while an agent is mid-turn,
generalized across Claude Code and codex, with no optimistic UI and no
content-matching.

The name: tapping someone on the shoulder while they work. You get their
attention without stopping them, and you can take it back before they turn
around.

---

## 1. What is wrong today

Minds paints an optimistic bubble the moment the user hits send, then waits for
the backend to confirm acceptance and flips it to "Queued". Two things are
broken about that, and they are different problems.

**The optimistic bubble is a lie with no expiry.** It is painted from a local
event — the click — not from anything the agent said. If the message is never
accepted, nothing takes the bubble down. There is no state in the system that
says "this send failed", only the absence of a confirmation that nobody is
waiting on.

**The confirmation signal does not fire for the case it is needed in.** For
codex, mngr confirms a send by watching the `active` marker set by the
`UserPromptSubmit` hook (`libs/mngr_codex/.../plugin.py`,
`_build_submission_evidence_probes`). That hook fires when a prompt *opens a
turn*. A message typed into a running turn does not open a turn — it is parked
in codex's steer queue and injected at the next tool-call boundary. So the
marker never advances, the probe polls its full 90-second window
(`DEFAULT_CONFIRMATION_TIMEOUT_SECONDS`), and `mngr message` reports failure for
a message that was accepted perfectly.

The plugin's own docstring concedes the gap:

> codex records no enqueue-style event (its raw transcript is the rollout
> JSONL), so the marker is the only per-submission evidence

That was true. It no longer is — the patch in this repo adds one. This document
is about what to build on top of it.

Claude's strict probe content-matches the message text against the transcript
(`_build_content_evidence_probe`), which works but is brittle in exactly the way
the Minds frontend's own FIXME complains about: two identical messages are
indistinguishable, and a message shorter than `_MIN_CONTENT_PROBE_LENGTH` falls
back to "any record appeared", which is barely evidence at all.

**The fix is not a better guess. It is to stop guessing.** Both harnesses can
tell you what happened to a queued message. One of them already does.

---

## 2. What each harness actually emits

Measured, not assumed. Both figures below come from reading live artifacts, not
from documentation.

### Claude Code

Claude writes a first-class record type to the session JSONL. From a real
6-hour session (`~/.claude/projects/<slug>/<session-id>.jsonl`), 106 of them:

```json
{"type":"queue-operation","operation":"enqueue","timestamp":"…","sessionId":"…","content":"…"}
{"type":"queue-operation","operation":"dequeue","timestamp":"…","sessionId":"…"}
{"type":"queue-operation","operation":"remove", "timestamp":"…","sessionId":"…","content":"…"}
```

| operation | count | carries `content` |
|---|---|---|
| `enqueue` | 53 | 31 yes / 22 no |
| `dequeue` | 27 | never |
| `remove`  | 26 | always |

The lifecycle is complete: a message goes in (`enqueue`), and it either becomes
a real turn (`dequeue`, immediately followed by a `user` record with a
`promptId`) or it is retracted (`remove`). Nothing is left dangling.

**What Claude does not give you is an id.** No field on any `queue-operation`
links it to the `user` record that follows, or to the `enqueue` it resolves.
Correlation is positional: the stream is per-session and ordered, so an
`enqueue` is matched to the next `dequeue` or `remove`, FIFO.

The `enqueue` records with no `content` are worth a note — do not treat a
missing `content` as an empty message. Match those positionally only.

### codex

Upstream codex emits nothing at all for a queued message. Its transcript is the
rollout JSONL, written by core; the queue lives in the TUI process and never
crosses into core until the message is actually injected.

The patch in this repo adds a sidecar, one line per queued message, at
`$CODEX_HOME/queued_input.jsonl`:

```json
{"type":"queued_input","queued_id":"f125a204-…","thread_id":"019fd9ae-…","timestamp":"…","content":"STEER_ALPHA"}
```

Claude has **a lifecycle and no id**; patched codex now has **both** — the
enqueue record plus `queued_committed` / `queued_retracted` terminal records,
each `{type, queued_id, timestamp}`.

| | codex (patched) | Claude Code |
|---|---|---|
| enqueue | yes, **with a stable id** (`queued_input`) | yes, content only |
| dequeue | yes (`queued_committed`) | yes |
| remove | yes (`queued_retracted`) | yes |
| correlation | by id, echoed on the rollout turn as `client_id` | positional, FIFO |

---

## 3. The semantic model

One vocabulary both harnesses map onto. Minds should be written against this and
nothing else.

A **tap** is a user message submitted while the agent is not able to start a turn
for it. It has exactly one of four states, and transitions are one-way:

```
                 ┌──────────► COMMITTED   (became a real turn)
   PENDING ──────┤
                 └──────────► RETRACTED   (pulled back out; never sent as written)

   REJECTED  (the harness refused it outright — never entered the queue)
```

- **PENDING** — accepted into the queue. The agent has it; it has not acted on
  it. This is the only state that renders as a shoulder-tap affordance.
- **COMMITTED** — injected into the conversation. There is now an ordinary user
  turn carrying this text. The tap affordance disappears; the message becomes a
  normal message.
- **RETRACTED** — removed before injection. The text is back in the user's hands
  (in codex's case, literally back in the composer). The tap affordance
  disappears and **no message is left behind.**
- **REJECTED** — never accepted. Distinct from RETRACTED because the user never
  had a moment where it looked accepted.

Three rules follow, and they are the whole design:

1. **A tap is only ever created by an observed harness event.** Never by the act
   of sending. There is no optimistic state.
2. **Every PENDING tap must reach a terminal state.** If your renderer can leave
   one PENDING forever, it is wrong. See §6.
3. **COMMITTED is proved by the conversation, not by the queue log.** The queue
   log says a message left the queue; only the transcript says it arrived.

---

## 4. Make codex emit the id it already supports — **shipped in v0.146.0**

Before building any of this, close the codex gap properly. Today the sidecar's
`queued_id` is generated locally and never echoed anywhere, so it correlates the
file only against itself — you still fall back to content matching to find the
committed turn.

**codex already has the plumbing for a caller-supplied message id and the TUI
simply declines to use it.** `client_user_message_id` runs the full path:

```
app-server request
  → core   (codex_thread.rs:281  submit_user_input_with_client_user_message_id)
  → UserMessageItem.client_id     (protocol.rs:2324)
  → persisted in the rollout as EventMsg(UserMessage).client_id
```

There is even an upstream test asserting the round trip
(`protocol.rs:5893`). The only reason it is unused is two literals in the TUI:

```rust
// codex-rs/tui/src/app_server_session.rs:920, 983
client_user_message_id: None,
```

**Change: pass the sidecar's `queued_id` there.** Then a queued message's id
appears verbatim on the committed turn in the rollout, and COMMITTED becomes a
key lookup instead of a text search. This is a genuinely small change —
threading one `Option<String>` that every layer beneath already accepts — and it
is what makes the rest of this spec cheap.

While in there, add the two missing lifecycle records so codex matches Claude:

| record | emit at |
|---|---|
| `queued_input` (exists) | `input_submission.rs:414`, the `pending_steers.push_back` site |
| `queued_committed` | where a steer is injected and the `UserMessage` is submitted to core |
| `queued_retracted` | `on_interrupted_turn` when steers drain back to the composer, and the `rejected_steers_queue` path |

Both new records need only `{type, queued_id, timestamp}` — the content is
already in the enqueue record and re-emitting it invites the two to disagree.

**Do not put these in the rollout.** That was settled in
[spec-queued-transcript.md](spec-queued-transcript.md) §4: the rollout is written
by core, the TUI reaches core through the in-process app-server, and appending a
rollout item from the TUI means a new protocol request, a processor, and a core
handler across four crates. The sidecar is the right shape; it just needs to be
complete.

---

## 5. Reading it: one adapter per harness

Each adapter is a pure function from harness artifacts to a stream of tap
events. It holds no UI state.

```
TapEvent = { tap_id, state, content?, timestamp, thread_id }
```

### codex adapter

Tail `$CODEX_HOME/queued_input.jsonl` and the rollout together.

- `queued_input` → emit PENDING with `tap_id = queued_id`.
- `queued_committed` → emit COMMITTED.
- `queued_retracted` → emit RETRACTED.
- Rollout `EventMsg(UserMessage)` with `client_id == tap_id` → COMMITTED. This
  is the authoritative one; the sidecar's `queued_committed` is a latency
  optimization so the UI can settle before the rollout write lands.

All three records ship in the current binary, so no content-matching stopgap is
needed.

### Claude adapter

Tail the session JSONL. Keep a FIFO of pending taps per `sessionId`.

- `queue-operation/enqueue` → push; emit PENDING with a **synthetic** `tap_id`.
  The id is yours, not Claude's — mint it and keep it.
- `queue-operation/dequeue` → pop the head; emit COMMITTED. Bind it to the
  `user` record that follows (it carries `promptId`), so the committed tap and
  the rendered message are the same object.
- `queue-operation/remove` → this one carries `content`; remove the **first**
  pending entry whose content matches, not the head. `remove` is user-initiated
  and need not be FIFO.

The positional pairing is safe because the stream is single-writer, ordered, and
per-session. It is not safe across sessions — key the FIFO on `sessionId` and
reset it on `SessionStart`.

### Why not one shared implementation

Resist it. The two harnesses agree on the semantic model and on nothing else:
different files, different record shapes, different correlation strategies,
one of which you can change and one of which you cannot. Share the `TapEvent`
type and the state machine; keep the parsers apart.

---

## 6. Rendering, and the rule that replaces optimism

**Paint nothing on send.** The send button's job is to deliver keystrokes and
return. The bubble appears when an adapter emits PENDING, and not before.

This costs a few hundred milliseconds of apparent latency and buys correctness.
If that latency is unacceptable, the honest version of optimism is a *distinct*
transient state — "sending", visually different from "queued" — that has a
**timeout**, and that resolves to an error if no PENDING arrives. Optimism with
an expiry is a spinner. Optimism without one is the current bug.

**Every PENDING gets a deadline.** Reconciliation rule, and it is the one thing
that makes all four of codex's known holes harmless:

> When a turn ends, any tap still PENDING that is not present in the transcript
> is RETRACTED.

This is not a fallback for a broken adapter. It is the correctness backstop, and
it single-handedly covers the codex cases that emit no retraction record today:

- Ctrl-C or a budget abort drains steers back to the composer
- core answers `ActiveTurnNotSteerable`
- a safety retry re-forks under a different `thread_id`
- the thread state is cleared

In every one of those the message is back in the user's hands and the
transcript has no record of it, so the rule fires and the badge comes down.

**The tap affordance itself.** A PENDING tap renders with its text and a single
action: *withdraw*. Nothing else is meaningful — you cannot edit a message the
agent may inject in the next fifty milliseconds. Withdraw maps to a `remove` on
Claude and, on codex, to Esc followed by clearing the composer, which is exactly
what the TUI already does.

**Ordering.** Render taps below the last committed turn, in enqueue order,
visually distinct from committed messages. They are not yet part of the
conversation. When one commits, it moves into the conversation at the position
the transcript gives it — which may not be where it was sitting, because codex
merges multiple steers into a single turn on Esc.

---

## 7. Failure modes worth designing for

**Multiple taps merging into one turn.** codex's `on_interrupted_turn` joins all
pending steers into one user turn with `\n`. Three PENDING taps then resolve to
one COMMITTED message. A renderer that assumes 1:1 will strand two of them
forever. With ids from §4 this is explicit — the committed turn carries one
`client_id` and the other two never appear — and §6's rule cleans them up. In
practice this is rare: measured live, three steers injected at successive tool
boundaries produced three separate turns, not a merge. The merge needs Esc
pressed while two or more steers are still parked.

**Duplicate content.** Two identical taps are indistinguishable under content
matching and perfectly distinguishable under ids. This alone justifies §4.

**Neither harness survives a restart.** codex's sidecar is not part of the
durable session and does not survive `codex resume`; Claude's queue is
in-memory. On reattach, treat all taps as gone and rebuild from the transcript
only. Do not try to resurrect a PENDING tap from a previous process — the
message either landed in the transcript or the user still has it.

**The unhooked queues.** codex has three input queues, and the sidecar observes
one. `pending_steers` is the shoulder-tap queue and the only one that matters
for this feature. `queued_user_messages` catches input while the session is
booting, a `!shell` command is running, plan mode is streaming, or a settings
popup is open; `rejected_steers_queue` holds steers core refused. Neither is on
the path a Minds user takes — they are chatting through a web UI, not typing
`!ls` — but if you want completeness later, the same `append_queued_input` call
at those two sites is all it takes.

---

## 8. Build order

Each step is useful on its own and none of them requires the next.

1. **Codex: thread `queued_id` into `client_user_message_id`.** Two literals in
   `app_server_session.rs`. Turns COMMITTED into a key lookup. Do this first —
   everything downstream gets simpler.
2. **Codex: add `queued_committed` and `queued_retracted`.** Brings codex to
   parity with Claude's lifecycle.
3. **Minds: the two adapters and the `TapEvent` state machine.** No UI yet;
   assert against recorded fixtures from both harnesses.
4. **Minds: the reconciliation rule (§6).** Before any rendering, so no tap can
   strand.
5. **Minds: replace the optimistic bubble** with PENDING-driven rendering plus
   the withdraw action.
6. **mngr: stop confirming codex sends with the `active` marker alone.** Add a
   sidecar probe so a mid-turn `mngr message` confirms in milliseconds instead
   of failing after 90 seconds.

Step 6 is worth calling out separately: it is a bug fix, not a feature, and it
is independent of the UI work. Right now `mngr message` to a busy codex agent
reports a delivery failure for a message that was delivered.

---

## 9. What this deliberately does not do

- **No new protocol requests, no core changes.** Everything here is TUI-side
  emission plus reader-side interpretation.
- **No durability.** Taps answer "what is happening right now". The durable
  record of a message is the transcript entry it becomes.
- **No queue manipulation.** Minds observes codex's and Claude's queues; it does
  not reorder, dedupe, or reimplement them. Ordering and draining stay exactly
  as the harness defines them.
