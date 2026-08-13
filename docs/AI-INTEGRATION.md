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

### 3.4 `cadence://` — the scripting entry point

For humans and their launchers (Raycast, a shell alias, a git hook). Agents want
§3.5 instead: a URL fires and forgets and cannot answer a question.

| URL | Does |
|---|---|
| `cadence://add?text=…` | Files a task. The **whole capture grammar** works — `#tag`, `@project`, `!2`, `~45m`, `tomorrow` — because the text goes through the same `CaptureParser` the composer uses. `title=` is accepted as an alias. |
| `cadence://start[?id=…]` | Starts the timer. Without an id, the same guess ⌥⇧Space makes: selection, then whatever the agenda says is underway or next. |
| `cadence://stop` | Stops every running timer. |
| `cadence://show?id=…` | Opens the detail panel for a task and brings the app forward. |
| `cadence://report` | Opens the time report. |

Writes do **not** steal focus (`open -g`); `show` and `report` obviously do.

`scripts/cadence` wraps these, and routes reads over the MCP endpoint below:

```sh
cadence add "Fix the flaky test #backend ~1h tomorrow"
cadence start          # or: cadence start <task-id>
cadence stop
cadence tasks 20       # reads — needs §3.5 switched on
cadence call get_time_report '{"from":"2026-08-01T00:00:00Z","to":"2026-08-08T00:00:00Z"}'
```

### 3.5 The endpoint other agents connect to

The same server, kept up for as long as the app runs, on a **fixed port** with a
token that survives relaunches (`ExternalAgentService`). Off by default; enabled
in Settings › AI › Other tools, which also prints the `claude mcp add` line.

- Token: `~/.config/cadence/mcp-token`, mode 600, generated once. A client
  configured today has to keep working tomorrow, which rules out the per-run
  token the app's own CLI gets.
- Client config: `~/.config/cadence/mcp.json`, rewritten on every start.
- Loopback only, bearer token on every request, unexpected `Origin` rejected —
  the same checks the per-run server makes.

**An external agent gets no shortcut to the database.** Its `propose_*` calls
land in a proposal buffer, are validated by the same `ProposalValidator`, and
appear as a banner above the workspace to accept or discard. The only immediate
writes are the journal tools and memory, which add rather than alter.

Staged changes are presented on a 1.5s debounce after the last write call (or
`explain`), so a plan arrives as one card rather than appearing half-built.

### 3.6 Unattended runs

`ScheduledRuns` fires two prompts nobody types (both off by default):

- **Nightly plan** — drafts tomorrow from tasks that already exist, sized
  against what the user's own records say they get through. Waiting as ghosts in
  the morning.
- **Weekly reflection** — reads a fortnight of tracked time and progress notes
  and writes what it implies into `memory`, reusing keys rather than
  accumulating contradictions. Changes nothing else.

Due-ness is **polled**, not timed: a Mac asleep at 21:00 never fires a timer set
for 21:00, but waking and asking "is it past the hour, and has today's run
happened?" survives that.

---

## 4. Tool catalog

Exposed over MCP. Read tools are unrestricted; write tools are **staged** — they
mutate a proposal buffer, not the database.

### Read

| Tool | Args | Returns |
|---|---|---|
| `list_tasks` | `status?, projectID?, tagIDs?, dueBefore?, unscheduledOnly?, limit` | tasks with estimates, scheduled **and tracked** minutes, due/defer |
| `get_task` | `id` | full task + notes + subtasks + blocks + its progress timeline |
| `get_time_report` | `from, to, includeNotes?` | time recorded in a range, totalled by project and task, plus the progress notes |
| `get_estimate_history` | `id` | what finished tasks with the same tags (or project) actually took: median, sample count, actual÷estimate |
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

### Write (immediate, not staged)

| Tool | Args |
|---|---|
| `log_progress` | `id, note, at?` — a line on the task's timeline |
| `log_time` | `id, from, to, note?` — a session the user did not time |
| `remember` / `forget` | see §6 |

These land straight in the database, like memory writes and unlike every task
edit. A timeline entry is a **journal**, not a change to the task: it adds a
line saying what happened rather than altering what the task *is*, nothing
downstream depends on it being right, and it is trivially deleted. Sending it
through the review buffer would put a modal in front of the one thing the user
just said out loud.

**Tracked time is the only evidence that can contradict an estimate.** Without
`trackedMinutes` and `get_estimate_history`, the model plans from the user's
optimism and has no way to notice that this kind of task always takes twice as
long as it is given. Prompts for estimating should call
`get_estimate_history` first.

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

- **Detect** searches `PATH`, `~/.local/bin`, `/opt/homebrew/bin` and the other
  usual install locations. Anything it cannot resolve to an executable file is
  run through the user's **login shell** instead, which covers the three shapes
  a custom wrapper usually takes:

  | Shape | Why the file lookup misses it |
  |---|---|
  | Shell alias | `command -v` answers `alias foo='…'`, not a path |
  | Shell function | `command -v` answers with the bare name |
  | Binary on a `PATH` from `.zshrc` | A GUI app never sees that `PATH` |

  Three details make that work, each of which silently breaks it if missed:

  - The shell is started `-ilc`, not `-lc`. `.zshrc` is only read by
    *interactive* shells, and that is where people put `PATH` and every alias.
  - The command line is wrapped in `eval`. zsh parses the whole `-c` string
    before the rc files have defined anything, and alias expansion happens at
    parse time.
  - The **command name is left unquoted** while every argument is quoted. A
    quoted word is never alias-expanded, so quoting the command breaks aliases;
    the arguments carry task titles and must be quoted, or an apostrophe would
    rewrite the command.

  A wrapper still has to accept the flags Cadence adds — `--mcp-config`,
  `--output-format`, `--append-system-prompt` — so one that drops unknown flags
  will fail no matter how it is resolved.

- **Finding the command is only half of it.** A wrapper resolved to a real file
  is run directly, with no shell in the way — and then it goes looking for its
  *own* dependencies in an environment that has never read `.zshrc`. A wrapper
  whose `claude` lives on an nvm/fnm/volta `PATH` reports “claude not installed”
  from inside Cadence while working perfectly in Terminal.

  So `LoginEnvironment` asks `zsh -ilc` once what it exports and every run
  starts from that: the shell's `PATH` first, then Cadence's own guesses as a
  fallback. Two things keep it honest:

  - Only the **environment** is taken, never the shell's stdout. rc files print
    banners and version notices; a marker is printed before `env -0` and
    everything ahead of it is discarded, or that noise would land in the JSON we
    parse.
  - `PWD`, `OLDPWD`, `SHLVL` and `_` are dropped — they describe the probe
    shell's session, not the run's, and the working directory is set explicitly.

  The capture is cached for the life of the process; it costs one interactive
  shell start (~0.7s here) the first time anything runs.
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
