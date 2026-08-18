# Working on Cadence

<!-- AGENTS.md is a symlink to this file, so both names serve identical
     content and cannot drift apart. Edit this one. -->

A native macOS task manager: tasks, drag-and-drop time blocking, and an AI
planner driven by the user's own local CLI. Personal tool, shipped publicly at
`okxiaochen/Cadence`.

## Build

```sh
xcodegen generate    # after adding files or editing project.yml
xcodebuild -project Cadence.xcodeproj -scheme Cadence -destination 'platform=macOS' build
xcodebuild -project Cadence.xcodeproj -scheme Cadence -destination 'platform=macOS' test
```

`Cadence.xcodeproj` is generated and gitignored — **edit `project.yml`, never the
project file**. New `.swift` files under `Cadence/` are picked up by path, but
`xcodegen generate` is still needed before they compile.

After changing anything the user will look at, rebuild **and relaunch** the app.
A stale running instance has caused "I can't see the changes" more than once.

## Release notes are shown in the app

`CHANGELOG.md` → `## Unreleased`. Add to it as you go; `./scripts/release.sh`
**refuses to publish while it is empty**, and turns the section into the
version's on the way out.

The rule has teeth in the script rather than living here alone, for the same
reason `testShippedMigrationIdentifiersAreStable` exists: a rule only a
document knows is a rule that gets skipped. Releases 0.1.0 through 0.10.0 went
out on `--generate-notes`, which is how nobody noticed.

Write them for **somebody in the update sheet**, not for GitHub. `ReleaseFeed`
reads the release body and `UpdateBanner` renders it as markdown in the panel
that offers the update — so the reader is deciding whether this is worth
restarting for. What is different for them, in their words. A list of commit
titles answers a question they did not ask.

## Release signing — read before touching releases

Releases are signed with an **Ed25519 key that exists only on this machine**:

```
~/.config/cadence/release-key      (mode 600, outside the repo, gitignored)
```

The matching public key is pinned in `Cadence/Update/ReleaseSignature.swift`.
Installed copies **refuse any update that key did not sign**.

Consequences worth holding on to:

- **Losing that file means losing the ability to update every existing install.**
  It cannot be regenerated — a new key produces signatures the shipped app
  rejects. Recovering needs a build trusting the new key, distributed by hand.
- `scripts/sign-release.swift keygen` refuses to overwrite an existing key, so
  running it is safe, but never delete `~/.config/cadence/`.
- `./scripts/release.sh <version>` does everything: version bump, tests, Release
  build, zip, sign, tag, push, GitHub release with both the zip and the `.sig`.
  A release published without the `.sig` asset is one nobody can install.

Key rotation is possible: `trustedPublicKeys` is an array, so ship a build
trusting old and new, then drop the old once installs have moved on.

## Signing

Builds are signed with a stable self-signed identity, `Cadence Self-Signed`, in
the login keychain (`./scripts/setup-signing-identity.sh` creates it). This is
**not** about Gatekeeper, which still rejects the app — it is about the
designated requirement. Ad-hoc signing makes that the binary's cdhash, so macOS
treats every build as a new app and calendar permission resets on every update.

Never move signing into `project.yml`: it is passed on the xcodebuild command
line so a clone without the certificate still builds, ad-hoc, with a warning.

## Data safety

The database is at `~/Library/Application Support/Cadence/cadence.sqlite`,
outside the bundle, so replacing the app never touches it.

- `eraseDatabaseOnSchemaChange` is **off**, including DEBUG, because a Debug run
  shares that file with the installed app. Opt in per run with
  `CADENCE_RESET_DB=1` when a reset is genuinely wanted.
- **Never write to the database with the `sqlite3` CLI.** It has
  `PRAGMA foreign_keys=OFF` by default, so `DELETE FROM task` leaves the tags,
  blocks and progress entries behind. Migrations run with foreign keys *on* and
  refuse to proceed, the app falls back to an in-memory database, and every list
  goes empty — which reads exactly like total data loss. `repairOrphans` now
  clears unreachable rows at startup and says so, but the fix is not to do it:
  use the app, `cadence://`, or the MCP endpoint.
- **Never edit or rename a shipped migration.** Users who ran it never run it
  again. Add a new one. `testShippedMigrationIdentifiersAreStable` guards this.
- The updater snapshots and verifies the database before every install.

## The window

Three workspaces (`Features/Root/RootView.swift`), and the order is the claim
the app makes about itself: **Chat**, **Knowledge**, **Schedule**. It began as a
task manager with an assistant bolted to the side and the window said so — a
list, a calendar, and a column you could open. It is now a companion that
happens to hold your calendar.

Each workspace brings **its own sidebar** (conversations / shelves / projects
and tags). Emptying the column in two of three reads as a bug, and hiding it
shifts the whole window sideways on every switch.

Knowledge is deliberately not under Settings, where it used to live. Nothing in
it is a preference — it is the assistant's own account of who you are, written
**unreviewed**, and the entire point of showing it is that the account can be
wrong and you are the only one who can say so. Behind a gear icon, a picture of
you that nobody looks at goes stale silently and takes every answer drawn from
it with it.

`AIPanelView` is one view in two shapes (`isPrimary`). As a column it is capped
so it cannot crush the calendar beside it; as the window it is uncapped, but the
transcript and the composer both sit on a ~760pt measure — a paragraph set
across a wide window runs past a hundred characters a line and the eye loses its
place coming back.

## Visual language

`Domain/Persona.swift` is who the companion is. The character is a **voice,
never a behaviour**, and that rule lives in `promptSection` rather than in each
voice so a new one cannot omit it — a blunt character that decides you do not
need to hear about a clash has stopped being a character. Every shipped voice
carries at least one *prohibition*, which is the part that actually moves a
model's register; a test enforces it. `dailyRemarks` sits on the persona because
how much somebody talks is not a preference about them, it is them — and it is
spent when something is **said**, not when a cadence is checked, so a morning of
`SKIP`s leaves the afternoon's one worthwhile remark affordable.

`Features/Shared/DesignSystem.swift` holds the spacing scale (`Metrics`), type
scale (`Typography`) and the shared row furniture. Use them rather than fresh
numbers — scattered ad-hoc values are most of what made this read as generic.

The recurring note from the user has been that it looked *functional but not
considered*, and the cause each time was **too many surfaces**: separate fills
per pane, a `Divider()` wherever two things met, and the same information said
twice (a tinted "today" column *and* a working-hours band over it). Prefer
whitespace to rules, one fill to three, and never state a thing two ways.

`Metrics` is deliberately not called `Layout` — that name collides with
SwiftUI's `Layout` protocol, which `FlowLayout` conforms to.

Window translucency lives in `WindowChrome.swift`. A material alone does
nothing: `.behindWindow` blending needs the `NSWindow` itself to be non-opaque,
and any view painting its own background (`.bar`, a `List`'s scroll background,
the toolbar) will punch an opaque hole straight through it.

Two hazards there, both already paid for:

- **`.hudWindow` forces a dark appearance** whatever the system is set to. It
  darkened the entire window and did not come back on switching style, because
  the material is applied to a view we do not own. Never pin `appearance` on
  those views either — inheriting is what keeps light/dark working.
- The split view's sidebar column has its own `NSVisualEffectView` beneath the
  `List`. Repainting it with the `.windowBackground` *material* is a near-miss
  of `windowBackgroundColor` and the seam shows — but **do not hide it**, since
  hiding an effect view takes its whole subtree with it and the sidebar's list
  is one of its subviews. Cover it with a colour behind the content instead.

## SwiftUI traps already hit here

- **Never hand a `Scene` a freshly built `Binding` from a computed property.**
  `MenuBarExtra(isInserted: someComputedBinding)` makes a new Binding on every
  Scene evaluation, SwiftUI reads that as a change, and the app spins at 100%
  CPU with no frame of our own code on the stack. Use `@AppStorage`/`@State`
  projected bindings, whose identity is stable.
- **Do not store a `Timer.publish(…)` in a View struct.** The struct is
  recreated on every render, so is the publisher. One `clock` on `AppModel`
  serves every view that shows "now".
- **`.offset` moves rendering and hit testing, not the layout frame.** An
  `.overlay` added *after* an offset is positioned against the un-offset frame
  and draws somewhere else entirely — near the container's origin. Put the
  overlay before the offset.
- **`.frame` proposes a size, it does not clip.** Text that wraps past the
  proposed height still draws, so a calendar block's background can cover the
  block below it. Clip explicitly.
- **`Color.clear.frame(width:)` is still flexible vertically** and will stretch
  a header row to fill the window.

When something spins, `sample <pid>` first. If none of our symbols appear in the
hot path it is a SwiftUI update loop, and bisecting by deleting scenes/views
finds it far faster than reading the code.

## Shape of the code

- `Domain/` — value types and pure logic (grouping, layout, capture parsing)
- `Store/` — GRDB. `AppModel` is the single object views read and write through;
  every mutation goes through `mutate`, which snapshots before/after so one
  action is one undo step.
- `Scheduling/` — `FreeBusy`, `SlotFinder`. **All availability maths is
  deterministic Swift.** The model picks among candidate slots and never
  computes when the user is free; this is the main reason AI scheduling is
  trustworthy.
- `AI/` — local MCP server over loopback with a per-run bearer token. The same
  server can also be kept up on a fixed port for *other* agents to drive
  (`ExternalAgentService`, off by default): their writes stage into a proposal
  and surface as a banner, so an outside agent can ask but never write.
  `ScheduledRuns` adds the three unattended prompts, and polls for due-ness
  rather than firing a timer — a sleeping Mac never fires the 21:00 timer. Task
  writes are `propose_*`, staged and reviewed. Memory writes land directly and
  self-correct via a stable key.

  The third unattended run, `portraitPrompt`, is what makes the companion a
  companion: every few days it reads recent conversations back through
  `read_conversations` and writes what they imply about the person, as
  `interest` memories rather than planning facts. Two rules there are load-
  bearing. `read_conversations` cannot see the unattended surfaces, **including
  its own** — otherwise it reads its own earlier guesses as evidence and gets
  more confident every pass without touching reality. And the prompt spends
  most of its length on what *not* to write: asked to summarise conversations, a
  model writes a diary ("asked about SwiftUI layout on Tuesday"), which is never
  true a second time and buries the four durable facts under three hundred. A configured command that is not an executable
  file (an alias, a shell function, a `PATH` from `.zshrc`) is run through
  `zsh -ilc` with the command bare, the arguments quoted, and the whole line
  under `eval` — see `docs/AI-INTEGRATION.md` §7 for why each part is needed.
- `Calendar/` — EventKit. Read as busy time; published to a dedicated calendar
  that **cannot be made read-only** (no such API), so the database wins and
  every reconcile overwrites.

Two invariants live in `TodoRepository`, so every path — drag, AI, quick
capture, undo — maintains them without call-site logic:

- one task has **one date and at most one time block**, and the date *is* the
  block's start;
- a scheduled task's **estimate is its block's length**. Resizing changes the
  estimate; editing the estimate resizes the block.

A `time_block` is a **plan**; `progress_entry` is the **record** — time actually
spent (a `session`, running while `endedAt` is null — several may run at once,
but never two on the same task) and
notes on where the work got to. "A task with several time segments" belongs
here, not in extra blocks: loosening the one-block rule would take the estimate
invariant with it.

On the grid both go through **one** layout pass (`CalendarLayout.position` over
`GridEntry`), so a session overlapping the block that planned it sits beside it,
the way any two overlapping events would. A narrow read-only lane was tried
first, to stop planned blocks halving in width whenever a timer started; a lane
narrow enough to leave the plan alone was too narrow to read, which defeats the
point of keeping a record. `SessionBlockView` is styled unlike `BlockView` —
dashed edge, lighter fill — and has a **minimum height**, since a ten-minute
session is four points tall at the default zoom.

Two rules the timer learned the hard way:

- **Timing a task must not touch its status.** Promoting `todo` to `doing` on
  start read well until you noticed nothing ever put it back — and Today matches
  `status = 'doing'`, so every task ever timed moved into Today permanently
  (`v7_release_timed_doing` cleans that up).
- **A clock nobody is watching gets closed.** `truncateAbandoned` cuts a session
  back to when the Mac went to sleep, or caps it at 8h, and says so in the
  entry's own note. Without it an overnight timer records a working day.

## Checking how it looks

`screencapture` works. Appearance **can** be verified from here, and claiming
otherwise wasted several rounds of the user's attention before anyone tried it.

```sh
B=$(osascript -e 'tell application "System Events" to tell process "Cadence" \
      to get {position, size} of window 1' | tr -d ' ')
screencapture -x -t png -R"$B" shot.png
```

Capture **that rectangle, never the whole screen** — a full-screen grab takes
whatever else the user has open with it.

**Measure pixels; do not look and decide.** A scrollbar fix was once read as
working off the rendered image and was not: the numbers were identical to the
broken build, byte for byte. Sample the columns and compare. `PIL` is available.

Two things still cannot be checked this way: **drag-and-drop**, which needs
input events, and anything about feel rather than appearance. Say so rather
than implying otherwise.

`LiveCLITests` run against the real `claude` CLI and spend the user's tokens —
opt in with `TEST_RUNNER_CADENCE_LIVE_CLI=1` and only when it earns it.
