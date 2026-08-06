# Working on Cadence

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

## Data safety

The database is at `~/Library/Application Support/Cadence/cadence.sqlite`,
outside the bundle, so replacing the app never touches it.

- `eraseDatabaseOnSchemaChange` is **off**, including DEBUG, because a Debug run
  shares that file with the installed app. Opt in per run with
  `CADENCE_RESET_DB=1` when a reset is genuinely wanted.
- **Never edit or rename a shipped migration.** Users who ran it never run it
  again. Add a new one. `testShippedMigrationIdentifiersAreStable` guards this.
- The updater snapshots and verifies the database before every install.

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

One task has **one date and at most one time block**; the invariant lives in
`TodoRepository` so every path maintains it without call-site logic.

## What cannot be verified from here

Screen recording is unavailable, so **drag-and-drop and general appearance have
never been confirmed visually**. Geometry and model behaviour are covered by
tests; how it looks and feels is not. Say so rather than implying otherwise.

`LiveCLITests` run against the real `claude` CLI and spend the user's tokens —
opt in with `TEST_RUNNER_CADENCE_LIVE_CLI=1` and only when it earns it.
