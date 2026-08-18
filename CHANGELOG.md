# Changelog

What changed, in the words of somebody deciding whether to install it.

These notes are **shown inside the app**: `ReleaseFeed` reads the GitHub
release body and `UpdateBanner` renders it in the update sheet. So they are
read by a person looking at a small panel, wondering whether this is worth
restarting for — not by anybody browsing a repository. Write what is different
for them. Commit titles are not that.

Add to `## Unreleased` as you go. `scripts/release.sh` refuses to publish while
it is empty, and turns it into the version's section on the way out.

## Unreleased

## 0.10.0 — 2026-08-17

The window is now three workspaces — **Chat**, **Knowledge** and **Schedule**,
on ⌘1 / ⌘2 / ⌘3. Talking to it is the app; your calendar is one of the things
it does rather than the thing it is.

- **The companion has a character.** Four to choose from — Mo, Pip, Sable and
  Yuna — and any of them can be copied and rewritten in your own words. How
  often it speaks up unasked is part of the character, so a quiet one stays
  quiet however many cadences you set.
- **It works out who you are.** A new unattended run reads your recent
  conversations every few days and writes down what they say about you —
  including what you care about away from work, which it had nowhere to put
  before. Off by default, under Settings → AI.
- **What it knows is a place now, not a settings tab.** Knowledge holds what it
  remembers about you and how it does things, and all of it is editable. It
  writes to memory without asking, so this is where you correct it.
- **A new "Anything?" button** on the companion. It says one thing it actually
  knows about you, or nothing at all.
- The assistant now uses what it knows in every reply, not only when planning
  your day.

Fixed:

- The companion no longer pops a bubble reading "SKIP" when a scheduled check
  had nothing worth saying.
- Its panel closes on its own once you have left it, instead of staying open
  until you go back and click it. A half-typed line keeps it open.
