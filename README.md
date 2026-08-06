# Cadence

A native macOS task manager with drag-and-drop time blocking and an AI agent
driven by your local AI CLI (`claude`, `codex`, …).

**Status:** M1–M5 built and passing — 189 tests, plus live end-to-end tests
against a real CLI covering scheduling and memory self-correction.

## Install

Download `Cadence-macOS.zip` from [Releases](../../releases), unzip, and drag
`Cadence.app` to `/Applications`.

The build is **ad-hoc signed only** — no Developer ID, no notarisation — so
Gatekeeper will refuse it on first launch. Either right-click the app and choose
**Open**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Cadence.app
```

Requires macOS 15 or later. Building it yourself avoids all of this.

Three view modes, switched from the toolbar or the View menu: **List**,
**Calendar**, and **Split** (list on the left, grid on the right — drag from one
to the other to schedule). The assistant panel opens with ⌘/.

## AI

Point Settings › AI at your CLI (`claude` by default) and press **Test
Connection**. Cadence hosts a local MCP server on 127.0.0.1 with a per-run
bearer token and hands the CLI a `--mcp-config` pointing at it. No API key is
stored; the CLI uses its own sign-in.

Everything the model does is staged and reviewed before it is saved. To run the
live end-to-end check (spends tokens on your subscription):

```sh
TEST_RUNNER_CADENCE_LIVE_CLI=1 xcodebuild -project Cadence.xcodeproj \
  -scheme Cadence -destination 'platform=macOS' \
  -only-testing:CadenceTests/LiveCLITests test
```

## Build

```sh
brew install xcodegen          # once
xcodegen generate              # regenerate Cadence.xcodeproj after adding files
open Cadence.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project Cadence.xcodeproj -scheme Cadence -destination 'platform=macOS' build
xcodebuild -project Cadence.xcodeproj -scheme Cadence -destination 'platform=macOS' test
```

`Cadence.xcodeproj` is generated — edit `project.yml`, never the project file.
New source files are picked up automatically by path, so `xcodegen generate`
is only needed when adding files or changing settings.

Data lives at `~/Library/Application Support/Cadence/cadence.sqlite`.
In DEBUG the migrator erases and rebuilds when the schema changes, so editing a
migration during development throws away local data — that is intentional for
now and must be removed before this holds anything worth keeping.

## What it is

- Tasks with projects, tags, notes, and subtasks
- A week/day calendar where you drag tasks onto the grid to schedule them
- Your real Apple Calendar shown behind your blocks as a read-only busy overlay
- An AI agent that can create, break down, and schedule tasks — invoked from
  buttons, a brain-dump composer, or a chat panel — always through a
  reviewable, undoable proposal

## Documents

| Doc | Contents |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | Product + technical specification |
| [docs/AI-INTEGRATION.md](docs/AI-INTEGRATION.md) | AI CLI bridge, tool catalog, interaction surfaces |

## Locked decisions

1. **macOS only.** No iPhone companion, no sync. Local SQLite.
2. **Apple Calendar is read-only.** We display busy time; we never write events.
3. **Single user (me).** No onboarding, no accounts, no App Store. Ship as a
   local `.app` built from Xcode.
