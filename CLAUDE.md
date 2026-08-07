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
- **Never edit or rename a shipped migration.** Users who ran it never run it
  again. Add a new one. `testShippedMigrationIdentifiersAreStable` guards this.
- The updater snapshots and verifies the database before every install.

## Visual language

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
  `List`. In solid mode it must be **hidden**, not repainted: `.windowBackground`
  as a *material* is a near-miss of `windowBackgroundColor` and the seam shows.

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
- `AI/` — local MCP server over loopback with a per-run bearer token. Task
  writes are `propose_*`, staged and reviewed. Memory writes land directly and
  self-correct via a stable key.
- `Calendar/` — EventKit. Read as busy time; published to a dedicated calendar
  that **cannot be made read-only** (no such API), so the database wins and
  every reconcile overwrites.

Two invariants live in `TodoRepository`, so every path — drag, AI, quick
capture, undo — maintains them without call-site logic:

- one task has **one date and at most one time block**, and the date *is* the
  block's start;
- a scheduled task's **estimate is its block's length**. Resizing changes the
  estimate; editing the estimate resizes the block.

## What cannot be verified from here

Screen recording is unavailable, so **drag-and-drop and general appearance have
never been confirmed visually**. Geometry and model behaviour are covered by
tests; how it looks and feels is not. Say so rather than implying otherwise.

`LiveCLITests` run against the real `claude` CLI and spend the user's tokens —
opt in with `TEST_RUNNER_CADENCE_LIVE_CLI=1` and only when it earns it.
