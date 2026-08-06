# Cadence — AI Integration

How the app talks to a local AI CLI (`claude`, `codex`, …), what the AI is
allowed to do, and how the user sees and controls it.

---

## 1. Principles

1. **One engine, many entry points.** Buttons, the composer, and chat all run
   the same agent loop over the same tool catalog. A button is a canned prompt.
2. **The AI decides, local code computes.** Free/busy math, date arithmetic, and
   conflict detection are deterministic Swift. The model chooses *which* slot,
   never *when the slot is*.
3. **Propose, then apply.** Nothing reaches the database until the user accepts.
   One AI turn = one undoable transaction.
4. **Everything is inspectable.** The exact argv, stdin, and raw output of every
   run is viewable and stored in `ai_run`.
5. **No API keys.** The CLI carries its own auth and billing. The app never
   holds a credential.

---

## 2. Interaction surfaces

### 2.1 Contextual actions — the daily path

Small buttons in place, no typing:

| Where | Action | Prompt sent |
|---|---|---|
| Task inspector | **Break down** | "Split this task into 3–7 concrete subtasks with estimates." |
| Task inspector | **Estimate** | "Estimate this task in minutes, using similar past tasks as reference." |
| Task inspector / row | **Find a slot** | "Schedule this task before its due date, respecting busy time and working hours." |
| Calendar toolbar | **Auto-schedule week** | "Place all unscheduled available tasks into this week." |
| Calendar toolbar | **Rebalance** | "Today got wrecked. Move what I missed into the rest of the week." |
| Multi-selection | **Triage** | "Assign a project, tags, priority, and estimate to each selected task." |

Each shows inline progress on the button, then opens the appropriate review UI.
Every one of these is also reachable from the ⌘K command palette.

### 2.2 Composer — "Generate Todos"

A sheet with a large text area for a brain dump, plus optional context controls:
a target project, default tags, and a date range.

```
┌── Generate Todos ────────────────────────────────┐
│ Need to ship the auth rewrite by Friday. That    │
│ means migrating the session store, updating the  │
│ login UI, writing migration docs, and I owe Sam  │
│ a review. Also book the dentist.                 │
│                                                  │
│ Project: [ Cadence ▾ ]  Tags: [ #work ]          │
│ ☑ Also propose a schedule                        │
│                        [ Cancel ] [ Generate ]   │
└──────────────────────────────────────────────────┘
```

Output is a **review list** — every proposed task as an editable row with
checkboxes, so you can drop the ones you don't want and fix titles before
applying. If "also propose a schedule" is checked, accepting the tasks
immediately produces ghost blocks in the calendar.

### 2.3 Chat panel — open-ended control

A right-hand panel (⌘/). Multi-turn, persists per session, references the
current selection and visible date range as implicit context.

```
You    ▸ move everything from thursday to friday, i'm out

AI     ▸ Found 4 blocks on Thu Aug 6.
         Friday has 3h free after your 10:00 standup.
         ┌ Proposed changes ────────────────────┐
         │ ☑ Write design doc  Thu 09:00 → Fri 11:00 │
         │ ☑ Review PRs        Thu 11:00 → Fri 13:00 │
         │ ☑ Fix login bug     Thu 14:00 → Fri 14:00 │
         │ ☐ Team sync         no free slot — needs  │
         │                     Mon or a shorter block│
         └──────── [ Apply 3 ]  [ Discard ]  ────────┘
         Ghost blocks are showing in the calendar.
```

Chat renders **structured proposal cards inline**, not walls of prose. The
calendar behind it shows the same proposals as ghost blocks, live.

Read-only questions ("what's my heaviest day?", "what's unscheduled and due
this week?") answer in text with no proposal card.

---

## 3. Execution model

### 3.1 Transport: a local MCP server

The app hosts an MCP server so the CLI can *pull* what it needs and *call*
tools, instead of the app stuffing a giant context blob into a prompt and
parsing prose back.

Because the app is already running and owns the database, **stdio transport is
wrong** (stdio requires the client to spawn the server). Use **HTTP on
127.0.0.1** with an ephemeral port and a per-run bearer token:

```
App start
  └ bind MCP server on 127.0.0.1:<ephemeral>, generate token

AI run
  ├ write mcp config to a temp file:
  │   { "mcpServers": { "cadence": {
  │       "type": "http",
  │       "url": "http://127.0.0.1:<port>/mcp",
  │       "headers": { "Authorization": "Bearer <token>" } } } }
  ├ Process: <cliCommand> -p "<prompt>" \
  │            --mcp-config <tmp> \
  │            --allowed-tools mcp__cadence__* \
  │            --output-format stream-json
  ├ stream stdout → parse events → update UI (text, tool calls, progress)
  └ on exit: rotate token, delete temp file, record ai_run
```

> Verify exact flag names against `claude --help` at implementation time — CLI
> flags change between versions. The design does not depend on the spelling,
> only on the capabilities: non-interactive prompt, MCP config, tool allowlist,
> streaming structured output.

Bind to loopback only, require the bearer token on every request, rotate the
token per run, and reject requests with an unexpected `Origin`.

### 3.2 Fallback: JSON in / JSON out

For a CLI without MCP support, the same tool catalog is expressed as a single
prompt: context JSON on stdin, a strict response schema in the prompt, one
validated JSON object out. One retry on schema-validation failure, with the
validator's error message fed back. Less capable (no iterative pulling) but
keeps the app CLI-agnostic.

The `AIProvider` protocol abstracts both, so surfaces don't know which is in use.

### 3.3 Run lifecycle

- Async, non-blocking, **cancellable** (SIGTERM, then SIGKILL after 3s).
- Hard timeout, default 120s, configurable.
- One run at a time per surface; a second invocation of the same button is a
  no-op while running.
- Streaming panel shows: status, elapsed time, tool calls as they happen, and a
  disclosure with raw stdout/stderr and the exact argv.
- Every run is written to `ai_run` regardless of outcome.

---

## 4. Tool catalog

Exposed over MCP. Read tools are unrestricted; write tools are **staged** — they
mutate a proposal buffer, not the database.

### Read

| Tool | Args | Returns |
|---|---|---|
| `list_tasks` | `status?, projectID?, tagIDs?, dueBefore?, unscheduledOnly?, limit` | tasks with estimates, scheduled minutes, due/defer |
| `get_task` | `id` | full task + notes + subtasks + blocks |
| `list_projects` | — | projects with task counts |
| `list_tags` | — | tags with usage counts |
| `get_schedule` | `from, to` | task blocks **and** Apple Calendar busy events |
| `find_free_slots` | `from, to, durationMinutes, count?, withinWorkingHours?` | ranked candidate slots — **computed locally** |
| `get_preferences` | — | working hours, timezone, week start, default estimate |

### Write (staged into a proposal)

| Tool | Args |
|---|---|
| `propose_create_task` | `title, notes?, projectID?, tagNames?, estimateMinutes?, dueAt?, priority?, parentID?` |
| `propose_update_task` | `id` + any mutable field |
| `propose_create_subtasks` | `parentID, subtasks[]` |
| `propose_schedule` | `taskID, startAt, endAt` |
| `propose_move_block` | `blockID, startAt, endAt` |
| `propose_delete_block` | `blockID` |
| `explain` | `summary, warnings[]` — the model's rationale and anything it couldn't do |

**`find_free_slots` is the linchpin.** It merges Apple Calendar busy time,
existing blocks, working hours, and a configurable minimum gap, then returns
concrete candidates. The model picks from that list. Without it, models
reliably produce blocks that overlap meetings or land at 3am.

### Validation before display

Every staged write is checked before it ever reaches the review UI:

- block start < end; duration between 5 min and 12 h
- no overlap with an existing block or a busy calendar event (unless the prompt
  explicitly asked to double-book)
- not in the past (unless explicitly asked)
- referenced IDs exist; the task isn't `done`/`cancelled`
- scheduling respects `deferAt` and lands before `dueAt` when one exists

Failures are not silently dropped — they appear in the review card as a
struck-through row with the reason, so the model's mistakes are visible.

---

## 5. Proposals

```swift
struct Proposal {
    let runID: String
    var changes: [Change]        // each individually toggleable
    var warnings: [String]
    var summary: String
}

enum Change {
    case createTask(TaskDraft)
    case updateTask(id: String, patch: TaskPatch, before: TaskSnapshot)
    case createBlock(BlockDraft)
    case moveBlock(id: String, from: DateInterval, to: DateInterval)
    case deleteBlock(id: String, snapshot: BlockSnapshot)
}
```

- Each `Change` carries a `before` snapshot so the review UI can render a real
  diff and undo is exact.
- **Rendering** depends on kind: scheduling changes become **ghost blocks** in
  the calendar (dashed, 50% opacity, draggable before acceptance); task changes
  become **diff rows** in the chat card or composer review list.
- **Applying** runs one DB transaction and registers one `UndoManager` action
  named after the run ("Undo Plan my week"). Partial acceptance applies only the
  checked changes.
- Proposals are ephemeral — discarded on window close or a new run in the same
  surface. `ai_run.appliedDiff` records what actually landed.

---

## 6. Context sent to the model

The system prompt is small and stable; the model pulls specifics via tools.

```
You are the scheduling agent inside Cadence, a personal macOS task manager.

Today is {date}, {weekday}. Timezone {tz}. Working hours {start}–{end}.
Week starts {weekStart}.

Use find_free_slots to locate time — never compute availability yourself.
Never schedule over busy calendar events unless explicitly asked.
Prefer longer contiguous blocks for tasks tagged #deep.
Respect due dates; if something cannot fit, say so in `explain` rather than
forcing it.
Stage all changes with propose_* tools; the user reviews before anything
is applied. Call `explain` last with a one-paragraph summary.
```

Plus a per-surface instruction (break down / generate / schedule / triage) and,
for chat, the current selection and visible date range.

Preferences that shape planning, editable in Settings and returned by
`get_preferences`: working hours per weekday, default estimate, minimum block
size, maximum focus hours per day, buffer between blocks, protected times
(e.g. "no meetings before 10am", "Friday afternoons free").

---

## 7. Configuration UI

Settings → AI:

```
Command      [ claude                                    ]  [ Detect ]
Arguments    [ -p                                        ]
Working dir  [ ~/                                        ]
Transport    ( • ) MCP over localhost   ( ) JSON in/out
Timeout      [ 120 ] seconds
             [ Test connection ]   ● Ready — claude 2.x
```

- **Detect** searches `PATH`, `~/.local/bin`, `/opt/homebrew/bin`.
  ⚠️ A GUI app's `PATH` is not the shell's `PATH`; resolve the binary to an
  absolute path and, if needed, run through a login shell to pick up the user's
  environment.
- **Test connection** runs a trivial prompt with one read tool and reports
  round-trip time and whether MCP tools were reachable.
- **Run history** lists past `ai_run` rows with prompt, argv, duration, applied
  changes, and raw output.

---

## 8. Failure handling

| Failure | Response |
|---|---|
| Binary not found / not executable | Disable AI surfaces, banner linking to Settings |
| Non-zero exit | Show stderr in the run panel; keep the raw output for inspection |
| Timeout | Kill, mark run failed, offer Retry |
| No parseable proposal | Show the raw text as a plain chat message; no proposal card |
| Schema-invalid tool args | MCP returns a validation error to the model, which retries (up to 2 tool-level retries) |
| Proposal fails app-side validation | Show struck-through rows with reasons; the rest stays applicable |
| Model produces zero changes | "Nothing to do" state with the model's `explain` text |

---

## 9. Build order within M3

1. `CLIRunner` — spawn, stream, cancel, timeout, `ai_run` persistence. Prove it
   with a hardcoded prompt before any UI.
2. MCP server + **read tools only**. Ask the CLI "what's due this week?" and get
   a correct text answer. This validates the whole transport.
3. `find_free_slots` + local scheduling math, unit-tested independently of AI.
4. Proposal model, validation, review sheet, transactional apply + undo.
5. Ghost blocks in the calendar.
6. Chat panel.
7. Canned-prompt buttons (trivial once 1–6 exist).
