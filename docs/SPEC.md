# Cadence — Specification

A native macOS task manager combining a task list, a drag-and-drop time-blocking
calendar, and an AI agent backed by a local AI CLI.

---

## 1. Goals

- **Capture is instant.** A global hotkey and a one-line parser; typing a task
  never requires touching the mouse.
- **Planning is physical.** Scheduling means dragging a task onto a calendar
  grid, not filling in two date pickers.
- **AI is a collaborator, not an oracle.** It proposes; I accept, edit, or
  reject; ⌘Z undoes it entirely.
- **The app is honest about time.** Blocks are placed around real meetings, and
  a task's estimate is compared against the time actually blocked for it.

### Non-goals

Collaboration, sharing, mobile, web, sync, accounts, App Store distribution,
writing to Apple Calendar, time tracking / pomodoro, habit tracking.

---

## 2. Locked decisions

| Decision | Choice | Consequence |
|---|---|---|
| Platform | macOS 15+, native SwiftUI (AppKit where needed) | No cross-platform |
| iPhone / sync | None | Plain local SQLite; no CloudKit constraints on the model |
| Apple Calendar | Read-only overlay via EventKit | No write-back, no conflict resolution |
| Audience | Just me | Skip onboarding, error-recovery polish, sandboxing |
| Sandbox | **Off** | Required to exec an arbitrary AI CLI binary. Also means no App Store — fine, we self-build. |
| Persistence | SQLite via GRDB | Real SQL for AI queries; stable migrations; no SwiftData rough edges |

---

## 3. Concepts

### 3.1 Task vs. TimeBlock

The central modeling decision: **a task is not a calendar event.** A task is
work to be done; a TimeBlock is an intention to work on it during a specific
window. One task may have zero, one, or many blocks.

This is what makes it possible to say "Write design doc — 3h estimate" and then
split it into Tue 9–11 and Wed 14–15, and to see at a glance that 3h of estimate
has 3h of blocks behind it.

### 3.2 Task states

```
inbox → todo → doing → done
                  ↘ cancelled
```

- `inbox` — captured, not yet triaged (no project assigned)
- `todo` — triaged, not started
- `doing` — actively in progress (at most a few at a time)
- `done` / `cancelled` — terminal, `completedAt` set

### 3.3 Subtasks

A `Task` may have a `parentID` pointing at another task. The UI enforces one
level of nesting (a subtask cannot itself be expanded); the schema allows more
so this can be relaxed later.

A subtask is a full task: it has its own estimate, notes, tags, and time blocks.
This matters because "AI, break this down and schedule the pieces" must produce
independently schedulable units.

Parent rollup: a parent shows `2/5` completion and the sum of child estimates.
Completing a parent completes remaining children (with confirmation).

---

## 4. Data model

SQLite. Times stored as ISO-8601 UTC strings; all-day values stored as local
date strings (`YYYY-MM-DD`) to avoid timezone drift.

```sql
CREATE TABLE project (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  colorHex    TEXT NOT NULL,
  symbolName  TEXT,               -- SF Symbol
  sortOrder   REAL NOT NULL,
  archivedAt  TEXT
);

CREATE TABLE tag (
  id       TEXT PRIMARY KEY,
  name     TEXT NOT NULL UNIQUE COLLATE NOCASE,
  colorHex TEXT NOT NULL
);

CREATE TABLE task (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  notes           TEXT NOT NULL DEFAULT '',   -- markdown
  status          TEXT NOT NULL,              -- inbox|todo|doing|done|cancelled
  priority        INTEGER NOT NULL DEFAULT 0, -- 0 none, 1 low … 3 high
  estimateMinutes INTEGER,
  projectID       TEXT REFERENCES project(id) ON DELETE SET NULL,
  parentID        TEXT REFERENCES task(id)    ON DELETE CASCADE,
  dueAt           TEXT,   -- hard deadline
  deferAt         TEXT,   -- hidden from "available" until this date
  sortOrder       REAL NOT NULL,
  createdAt       TEXT NOT NULL,
  updatedAt       TEXT NOT NULL,
  completedAt     TEXT
);

CREATE TABLE task_tag (
  taskID TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  tagID  TEXT NOT NULL REFERENCES tag(id)  ON DELETE CASCADE,
  PRIMARY KEY (taskID, tagID)
);

CREATE TABLE time_block (
  id        TEXT PRIMARY KEY,
  taskID    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  startAt   TEXT NOT NULL,
  endAt     TEXT NOT NULL,
  isAllDay  INTEGER NOT NULL DEFAULT 0,
  source    TEXT NOT NULL,     -- manual | ai
  createdAt TEXT NOT NULL
);
CREATE INDEX idx_block_range ON time_block(startAt, endAt);

-- What actually happened on a task, as against the plan above. A `session` is
-- time spent (running while endedAt is NULL — several tasks may run at once,
-- never two on one task; `allowsConcurrentTimers` off makes it one at a time);
-- a `note`
-- is a line of progress with no duration. A task has at most one time_block but
-- any number of these.
CREATE TABLE progress_entry (
  id        TEXT PRIMARY KEY,
  taskID    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  kind      TEXT NOT NULL DEFAULT 'note',   -- session | note
  note      TEXT NOT NULL DEFAULT '',
  startedAt TEXT NOT NULL,
  endedAt   TEXT,
  createdAt TEXT NOT NULL,
  externalEventID TEXT   -- set when publishing tracked time to Apple Calendar
);
CREATE INDEX idx_progress_task  ON progress_entry(taskID, startedAt);
CREATE INDEX idx_progress_range ON progress_entry(startedAt, endedAt);

-- AI runs, for history and undo attribution
CREATE TABLE ai_run (
  id          TEXT PRIMARY KEY,
  surface     TEXT NOT NULL,   -- chat | breakdown | generate | schedule | estimate
  prompt      TEXT NOT NULL,
  command     TEXT NOT NULL,   -- exact argv executed
  rawOutput   TEXT NOT NULL,
  status      TEXT NOT NULL,   -- running | succeeded | failed | cancelled
  startedAt   TEXT NOT NULL,
  finishedAt  TEXT,
  appliedDiff TEXT             -- JSON of what was actually applied
);
```

**Derived, not stored:** "available" (status ∈ {todo,doing} AND (deferAt is null
OR deferAt ≤ today)), "scheduled minutes" (sum of block durations),
"unscheduled" (estimate > scheduled minutes).

**Apple Calendar events are never persisted.** They are fetched live from
EventKit per visible date range and rendered as a background layer.

---

## 5. UI

### 5.1 Window layout

```
┌──────────────┬───────────────────────────────┬──────────────┐
│  SIDEBAR     │   MAIN (List | Calendar)      │  INSPECTOR   │
│              │                               │              │
│ ▸ Today      │  ── switchable, or split ──   │  Title       │
│ ▸ Upcoming   │                               │  Project ▾   │
│ ▸ Inbox      │                               │  Tags        │
│ ▸ Anytime    │                               │  Estimate    │
│              │                               │  Due / Defer │
│ PROJECTS     │                               │  ───────     │
│  ● Cadence   │                               │  Notes       │
│  ● Personal  │                               │  (markdown)  │
│              │                               │  ───────     │
│ TAGS         │                               │  Subtasks    │
│  #deep       │                               │  Blocks      │
│  #errand     │                               │              │
└──────────────┴───────────────────────────────┴──────────────┘
                                                  ⌘/ toggles AI panel →
```

The AI chat panel slides in as a fourth column (or over the inspector).

### 5.2 Modes

Two main-area modes, toggled with ⌘1 / ⌘2, plus a **split mode** (⌘3) that puts
the task list on the left and the calendar on the right — this is the mode
you'll use for planning, since dragging list → calendar requires both visible.

### 5.3 Task list

- Flat rows, subtasks nested one level with disclosure triangles.
- Group by: none / project / tag / due date. Sort by: manual / due / priority.
- Row shows: checkbox, title, project dot, tag chips, estimate, due badge, and a
  small clock icon if scheduled.
- Inline edit on click; ⏎ creates a sibling below; ⇥ / ⇧⇥ indent / outdent.
- Multi-select with ⇧/⌘, then bulk edit project/tag/status via the inspector.

### 5.4 Quick capture

Global hotkey (default ⌥Space) opens a floating one-line field. Input is parsed
locally — **no AI call**, it must be instant:

```
Fix login bug #bug @Cadence !2 ~45m tomorrow 3pm
 └ title      └tag └project └pri └estimate └ date/time → creates a block
```

Grammar: `#tag`, `@project`, `!1..3` priority, `~30m|~2h` estimate, and a date
phrase parsed by a local recognizer (`NSDataDetector` plus a small custom pass
for "tomorrow", "next tue", "eod"). Unparsed remainder is the title. Tokens are
highlighted live so it's obvious what was understood.

Only if the local parse yields nothing useful **and** the text is long does the
UI offer "→ Generate with AI".

### 5.5 Calendar

- **Views:** Day, 3-Day, Week (⌘⌥1/2/3). Week starts Monday.
- **Grid:** 15-minute rows, zoomable (⌘+ / ⌘−) between 30px/hr and 200px/hr.
  All-day lane pinned at top. Red current-time line. Working-hours band
  (default 09:00–18:00) shown brighter; outside hours is dimmed but usable.
- **Busy overlay:** EventKit events render as flat grey blocks *behind* task
  blocks, with title and a lock affordance (not draggable, not editable).
  Calendar picker in Settings chooses which calendars count as busy.
- **Drag from list → grid:** creates a block of `estimateMinutes` (default 30).
  A live drop preview shows the resulting time span.
- **Drag within grid:** moves the block. **Drag edges:** resizes → changes end
  (or start) time. Snap to 15 min; hold ⌥ for 1-minute precision.
- **⌥-drag** duplicates a block (for splitting work across days).
- **Drag out / ⌫:** deletes the block, task returns to unscheduled.
- **Overlap layout:** standard interval-column packing — overlapping blocks
  share the column width side by side.
- **Ghost blocks:** AI proposals render as dashed, semi-transparent blocks with
  an accept/reject bar floating above the view. They are not persisted until
  accepted. Individual ghosts can be dragged before accepting.
- Every mutation registers with `UndoManager` with a descriptive action name
  ("Move Write design doc").

### 5.6 Inspector

Selected task detail: title, project, tags, status, priority, estimate, due,
defer, markdown notes (edit/preview toggle), subtask list (inline add,
drag-reorder), and the list of time blocks with a "+ Find a slot" AI action.

Shows a **budget line**: `2h estimated · 1h30m blocked · 30m short`.

### 5.7 Menu bar

Always-present status item showing the current or next block and time remaining.
Click → today's agenda, quick-add field, and "Ask AI…". This is the primary
surface when the main window is closed.

---

## 6. Notifications

Local notifications via `UserNotifications`. All are toggleable in Settings.

| Trigger | Content | Actions |
|---|---|---|
| Block start | "Write design doc — now until 11:00" | Start · Snooze 10m · Reschedule |
| Block start − N min (default 5) | "Up next: Write design doc at 09:00" | — |
| Due date, 09:00 local | "Ship v2 is due today" | Schedule now · Snooze |
| End of day (default 17:30) | "3 tasks due tomorrow, 2 unscheduled" | Plan with AI · Dismiss |

"Start" sets the task to `doing`. "Reschedule" opens the calendar with that
block selected. Notification scheduling is recomputed on every block mutation
(cancel + reschedule pending requests for affected tasks).

---

## 7. Architecture

```
CadenceApp (SwiftUI)
├── Features/            views + view models per area
│   ├── TaskList/  Calendar/  Inspector/  QuickCapture/  AIPanel/  MenuBar/
├── Domain/              value types: Task, Project, Tag, TimeBlock, Proposal
├── Store/               GRDB: schema, migrations, repositories,
│                        ValueObservation → @Observable stores
├── Calendar/            EventKitService (read-only busy fetch, change observer)
├── AI/                  CLIRunner (Process), MCPServer, ToolCatalog,
│                        AgentSession, ProposalEngine
├── Scheduling/          local slot-finding (free/busy math) — used by AI tools
└── System/              Notifications, GlobalHotkey, UndoCoordinator, Settings
```

Key points:

- **One writer.** All mutations funnel through repository methods that take a
  `Transaction`, so an AI turn and a drag are the same kind of operation and
  both get one undo entry.
- **Reactive reads.** GRDB `ValueObservation` feeds `@Observable` stores; views
  never query directly.
- **Slot-finding is local code, not AI.** `Scheduling/` computes free/busy
  windows deterministically from EventKit events, existing blocks, and
  working-hours preferences. The AI *chooses among* candidate slots; it never
  does arithmetic about them. This is the single biggest reliability win.

### Tech stack

| Concern | Choice |
|---|---|
| UI | SwiftUI; AppKit (`NSViewRepresentable`) for the calendar grid drag layer if SwiftUI gestures prove insufficient |
| DB | SQLite + GRDB.swift |
| Calendar read | EventKit (`NSCalendarsUsageDescription`, full-access request) |
| Notifications | UserNotifications |
| Global hotkey | Carbon `RegisterEventHotKey` or KeyboardShortcuts package |
| Markdown | Native `AttributedString(markdown:)` for preview; plain `TextEditor` for edit |
| AI transport | `Process` + a local MCP server (see AI-INTEGRATION.md) |
| Min target | macOS 15 |

**Toolchain note:** this machine has Xcode 16.4 (macOS 15 SDK) on macOS 26.
That builds fine for a macOS 15 target. Installing Xcode 26 is only needed to
adopt macOS 26-only APIs.

### Entitlements

App Sandbox **disabled** — mandatory for spawning a user-specified CLI binary.
Also needs the calendars entitlement and a usage description string. Signed
locally for personal use; no notarization needed for a self-built app.

---

## 8. Roadmap

Each milestone should be usable on its own.

### M1 — Task spine ✅ built
Schema + migrations, projects, tags, task CRUD, subtasks, markdown notes,
sidebar smart lists (Today/Upcoming/Inbox/Anytime/Logbook), grouping and
sorting, multi-select, undo, quick capture with the local parser.
*Done when: I've stopped using my previous todo app.*

Implementation notes:
- The Swift type is `Todo`, not `Task`, so it does not shadow Swift
  concurrency's `Task`. The table is still `task`.
- Dates are stored via GRDB's default encoding (`YYYY-MM-DD HH:MM:SS.SSS`,
  UTC) — text, and lexicographically comparable, which is what the smart-list
  SQL relies on.
- Swift 5 language mode. Swift 6 strict concurrency across GRDB observation
  callbacks is a fight worth having later, not while the app is taking shape.
- Remaining M1 polish: drag-to-reorder in the list (the `move(_:after:)`
  repository call exists, the list has no drop target yet), ⇥/⇧⇥ to indent and
  outdent, and a real Settings window.

### M2 — Calendar ✅ built
Day/3-day/week grid, TimeBlock model, drag list→grid, move, resize, ⌥-duplicate,
unschedule, overlap layout, EventKit busy overlay + calendar picker, working
hours, split mode, budget line in the inspector.
*Done when: I plan a full week by dragging.*

Implementation notes:
- **`FreeBusy` is pure interval maths, unit-tested independently.** The grid
  uses it to shade busy time and flag conflicts; `find_free_slots` in M3 is
  built on the same functions. The model never does this arithmetic (§7).
- Overlap packing clusters blocks transitively (A∩B, B∩C ⇒ one cluster of
  three) so widths line up, then greedily reuses columns once a block ends.
- Drag and resize use `DragGesture` in a named grid coordinate space, so
  `x` maps onto a day column and cross-day drags work in week view. Cursor
  position → date goes through `CalendarGeometry`, which snaps and clamps.
- Blocks are clamped to their own day; a block cannot span midnight.
- Conflicts (with other blocks or real events) are shown as a warning badge,
  never enforced — deliberate double-booking is allowed.
- Remaining M2 polish: dragging a block off the grid to unschedule it (⌫,
  the context menu, and the Calendar menu do it today); creating all-day
  blocks (the all-day lane currently renders calendar events only); and a
  drop indicator while dragging from the list.

### M3 — AI ✅ built
CLI configuration + health check, MCP server, tool catalog, agent session loop,
proposal/ghost-block review, undo of an AI turn, run history. Surfaces: chat
panel (⌘/), "Break Down", "Estimate", "Find a Slot", "Generate Todos",
"Plan Week".
*Done when: "plan my week" produces a schedule I accept without editing.*

Implementation notes:
- Verified end to end against the real `claude` CLI: the model called
  `list_tasks` → `get_schedule` → `find_free_slots` → `propose_schedule` →
  `explain`, wrote nothing, and the reviewed block applied cleanly.
- `SlotFinder` does all availability maths; the model only picks among the
  candidates it returns. This is the single biggest reliability decision.
- Write tools are `propose_*` and stage into a `ProposalBuffer`. Validation runs
  against the live database *after* the run, so anything that went stale is
  caught. Rejected changes are shown struck through with a reason, never
  silently dropped.
- Calendar events reach the model as opaque busy intervals — it learns *when*
  you are busy, never *what* you are doing.
- Remaining M3 polish: the composer "Generate Todos" flow reuses the chat
  review card rather than the dedicated editable task list from §2.2; ghost
  blocks are not yet draggable before acceptance; run history is persisted to
  `ai_run` but has no browser UI.

### M4 — Mac citizenship
Notifications with actions, menu bar agenda, global hotkey polish, launch at
login, Settings window, ⌘K command palette, full-text search.

### M4 — Calendar publish & floating detail ✅ built
One-way publish of blocks into a dedicated "Cadence" calendar, sidebar
simplified to Today/Upcoming/Anytime/Logbook, task detail moved from a sidebar
column to a floating panel.

Implementation notes:
- **A published calendar cannot be made read-only.** `allowsContentModifications`
  reflects what the *source* permits and cannot be set; only subscribed
  calendars are truly read-only, and those cannot be written to. So the database
  is the source of truth and every reconcile overwrites the calendar. An edit
  made in Calendar.app survives until the next sync.
- Published events are excluded from the busy overlay. Without that every
  scheduled task would collide with itself and the AI would refuse to place
  anything.
- `time_block.externalEventID` pairs a block with its event; the reconcile is
  idempotent and only writes events that actually changed.
- The Inbox smart list is gone; `Anytime` is the catch-all and now includes
  deferred tasks, since they have nowhere else to live. `TodoStatus.inbox`
  survives only so old rows decode; migration v3 folds them into `todo`.
- Detail is a floating `NSPanel`, not a popover: detail opens from list rows
  *and* calendar blocks, and a block's task is often absent from the current
  list, leaving nothing to anchor a popover to.

### M5 — Assistant memory ✅ built
Durable facts the assistant consults when planning: preferences, projects,
goals, constraints, routines.

Implementation notes:
- **Two tiers.** Pinned memories are injected in full; everything else is one
  outline line each, capped at 30 entries / 2,000 characters. The model calls
  `get_memory(key)` for detail, so a growing memory never crowds out the request.
- **Self-correcting by construction.** Memories are keyed by a model-chosen slug
  and `remember` upserts, so revising a belief *replaces* it. Keys are
  normalised (`Meeting Times` → `meeting-times`) or near-misses would quietly
  create a second, contradicting memory. Verified live: telling the assistant a
  preference had changed rewrote the same key rather than adding a rival entry.
- **Written directly, not staged.** Memory is the assistant's own note about how
  to plan rather than a change to the user's data; gating it behind review would
  mean it never learns. Everything is listed and editable in Settings › Memory.
- `lastUsedAt` is bumped by `get_memory`, so the outline surfaces what actually
  gets used and cold memories sink.

### M6 — Later, if wanted
Recurrence (`EKRecurrenceRule` semantics), saved smart filters with a small
query DSL, review mode (weekly review flow), export/import JSON, Shortcuts
actions, per-project time budgets.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Calendar drag layer is the hardest UI; SwiftUI gestures may fight the scroll view | Time-box a SwiftUI spike in M2; fall back to an AppKit `NSView` grid with manual hit-testing |
| AI returns plausible-but-wrong schedules (overlaps, past times, ignoring meetings) | Slot math is local and deterministic; validate every proposed block against free/busy before showing it; reject invalid ones with a visible reason |
| CLI latency (10–60s) makes AI features feel broken | Always async, always streaming, always cancellable; never block the UI; buttons show inline progress |
| Sandbox-off + exec'ing a binary is a real security surface | Personal app; command is explicitly configured by me, argv shown in the run detail view |
| Scope creep into a full PIM | Non-goals list above is binding; M5 items stay in M5 |

---

## 10. Open questions

1. **Where does an AI-created task land?** Proposal: `inbox` unless the prompt
   named a project.
2. **Should completing all subtasks auto-complete the parent?** Proposal: no,
   but show a nudge.
3. **Should a block whose task is completed early auto-shrink?** Proposal: no,
   but offer "free up remaining time" in the completion toast.
4. **Multiple AI CLIs configured at once** (e.g. `claude` for chat, a cheaper
   one for parsing)? Proposal: single command in M3, profiles later.
