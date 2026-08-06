# Queued input in the codex transcript — spec

Goal: when a user types while a turn is running, codex should record that in its
transcript, not only in memory — the way Claude Code already does.

Status: spec only. Nothing built.

---

## 1. Why this matters

mngr confirms a message was accepted by looking for evidence in the agent's
transcript. The two harnesses are not equal here, and the codex plugin already
says so out loud:

> codex records no enqueue-style event (its raw transcript is the rollout
> JSONL), so the marker is the only per-submission evidence, for slash commands
> and normal messages alike
>
> — `libs/mngr_codex/imbue/mngr_codex/plugin.py:407`

So today:

| | evidence mngr uses | strength |
|---|---|---|
| claude | `queue-operation`/`enqueue` + `user` records, matched on decoded content | proves **which** message landed |
| codex | mtime of the `active` marker file advancing | proves **something** landed |

The codex probe cannot tell one message from another, and it cannot see a
message at all until a turn opens. Anything sitting in the queue is invisible to
Minds — the UI cannot show it, and a crash loses it with no record it ever
existed.

---

## 2. How Claude Code does it

Measured across 67 real transcripts in `~/.claude/projects`, not inferred.

Three record types, appended to the same session JSONL as everything else:

```json
{"type":"queue-operation","operation":"enqueue","timestamp":"...","sessionId":"...","content":"Reply with exactly: OK2"}
{"type":"queue-operation","operation":"dequeue","timestamp":"...","sessionId":"..."}
{"type":"queue-operation","operation":"remove","timestamp":"...","sessionId":"...","content":"<task-notification>..."}
```

Counts across those transcripts:

```
enqueue  1103
dequeue   976
remove    127
           ↳ 976 + 127 = 1103, exactly
```

**Every enqueued item terminates exactly once**, as either a dequeue or a
remove. That is the invariant to preserve.

### The part that answers "how does it get updated"

It doesn't. **The enqueue line is never mutated.**

JSONL is append-only, so a state change is a *new event*, not an edit. A message
entering the conversation looks like this:

```
queue-operation/enqueue   content recorded the instant it is queued
queue-operation/dequeue   no content — the FIFO head is being sent
attachment ×N
user                      the real message, content verbatim from the enqueue
assistant ...
```

Anything reading the transcript reconstructs current queue state by replaying
the operation sequence. There is no "current queue" record to read.

### Two weaknesses worth not copying

- **`dequeue` carries no content and no id.** Correlation is positional — the
  head of the queue. `remove` *does* carry content, so with removes interleaved
  a reader must model the whole queue to know what a dequeue referred to.
- **Positional matching is genuinely fragile.** Checking whether enqueued text
  reappears verbatim in the following `user` record: two of three sampled cases
  matched exactly, and the third picked up a *different* message that happened
  to be nearby. A naive reader gets this wrong.

`remove` in practice is mostly `<task-notification>` payloads that were
superseded before they ran.

---

## 3. What codex has

**The queue is in the TUI.** `tui/src/chatwidget/input_queue.rs`:

```rust
pub(super) struct InputQueueState {
    pub(super) queued_user_messages: VecDeque<QueuedUserMessage>,
    pub(super) rejected_steers_queue: VecDeque<UserMessage>,
    pub(super) pending_steers: VecDeque<PendingSteer>,
    ...
}
```

Note there are **three** queues, not one. Scope decision below.

**The transcript is written by core.** The rollout JSONL is owned by
`core/src/session/`, which also owns rotation and truncation
(`core/src/thread_rollout_truncation.rs`).

**There is an extension point.** `RolloutItem` (`protocol/src/protocol.rs:3186`)
carries an `EventMsg(EventMsg)` variant, and core already persists events
through it:

```rust
// core/src/session/handlers.rs:523
sess.persist_rollout_items(&[RolloutItem::EventMsg(rollback_msg.clone())]).await;
```

`ext/goal/src/api.rs:68` does the same for `ThreadGoalUpdated`. So writing a
non-model-visible event into the transcript is an established pattern, not a new
mechanism.

---

## 4. The one real architectural problem

Claude Code has a single process owning both the queue and the transcript
writer. codex does not: **the TUI holds the queue, core holds the file, and
there is no existing path for the TUI to append a rollout item.**

| option | verdict |
|---|---|
| **A. New `Op` + core handler.** TUI sends an op; the core handler calls `persist_rollout_items`. | **Recommended.** Preserves a single writer and reuses the `handlers.rs:523` pattern exactly. |
| B. TUI writes the rollout file directly. | Rejected. Two writers on one file, and core owns truncation and rotation — a TUI append can land inside a rewrite. |

This is why the patch is structurally bigger than the `/model` and `/fast` ones:
those were `tui`-only, this crosses `protocol`, `core`, and `tui`.

---

## 5. Proposed design

### Event

```rust
pub struct QueueOperationEvent {
    pub thread_id: ThreadId,
    pub operation: QueueOperation,   // Enqueue | Dequeue | Remove
    pub queued_id: Uuid,             // assigned at enqueue
    pub content: Option<String>,     // Some on enqueue, None on dequeue/remove
}
```

carried as `EventMsg::QueueOperation(..)` inside `RolloutItem::EventMsg`.

**Deliberate departure from Claude:** every operation references an explicit
`queued_id`. Claude's positional correlation is the weakness measured in §2, and
there is no reason to reproduce it. A reader matches by id and never has to
replay the queue.

### Emit points

In `input_queue.rs` / `chatwidget`, at the three points that already mutate the
queue:

| when | operation |
|---|---|
| a message is pushed onto `queued_user_messages` | `Enqueue` |
| it is popped and submitted to core | `Dequeue` |
| it is cleared or edited out before sending | `Remove` |

Preserve the invariant: **exactly one terminating event per enqueue.**
`InputQueueState::clear()` must emit a `Remove` per surviving entry, or the log
silently leaks entries that never terminate.

### Scope question

Start with `queued_user_messages` only. `pending_steers` and
`rejected_steers_queue` are a different concept — mid-turn steering, not queued
turns — and folding them in would make the event mean two things. Add later if
Minds needs steer visibility.

---

## 6. What mngr gets

`_build_submission_evidence_probes` for codex can move from the `active`-marker
probe to a content-matched jq filter, the way claude's already works:

```
fromjson? | select(.type == "event_msg" and .payload.type == "queue_operation")
```

That closes the gap in the table in §1 — codex gets per-message submission
confirmation instead of "something happened".

---

## 7. Risks

- **Resume replay must ignore it.** `core/src/session/rollout_reconstruction.rs`
  replays the rollout. A queue event must never become model-visible history.
  Encouraging: `protocol.rs:3015` and `memories/write/src/phase1.rs:419` already
  fall through `RolloutItem::EventMsg(_) => None`, and
  `thread-store/src/thread_metadata_sync.rs` matches specific events with a
  catch-all — so a new variant is inert by default. **Verify, don't assume.**
- **Content duplication.** The message text lands in the transcript twice, once
  at enqueue and once as the real `user` record. Claude accepts this. It costs
  transcript bytes and interacts with rollout truncation budgets.
- **Cross-crate patch.** `protocol` + `core` + `tui`, versus `tui`-only for the
  existing patches. More surface to re-verify on each codex version bump.

## 8. Effort

Materially larger than `/fast on|off`: a new protocol event, a new `Op` and core
handler, three TUI emit points, and replay-inertness tests. Call it a day's work
with the dev-box loop, most of it in verification rather than code.

## 9. Open questions

1. Queued turns only, or steers too? (Recommend: queued turns only to start.)
2. Should `Dequeue` echo the content, so a reader never needs the enqueue line?
   (Recommend: no — that is what `queued_id` is for.)
3. Do we upstream this? It is a genuine gap, and unlike the lockdown it is not
   Minds-specific.
