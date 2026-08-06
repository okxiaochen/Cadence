# Releasing, and what happens to user data

## Cutting a release

```sh
./scripts/release.sh 0.2.0
```

That bumps `MARKETING_VERSION` in `project.yml`, runs the tests, makes a Release
build, zips the app, commits, tags `v0.2.0`, pushes, and publishes a GitHub
release with the zip attached. The version in the bundle and the git tag come
from the same place, so they cannot drift.

Users update by downloading the new zip and replacing `/Applications/Cadence.app`.
The app also checks for updates itself — see [Auto-update](#auto-update) below.

---

## Does user data survive an update?

**Yes.** The database lives at

```
~/Library/Application Support/Cadence/cadence.sqlite
```

which is outside the app bundle. Replacing `Cadence.app` does not touch it.
Settings live in `UserDefaults` under `dev.xiaochen.Cadence`, which likewise
survives, so the AI CLI configuration, working hours and the published-calendar
link all carry over.

On launch the app runs any migrations the database has not seen yet, in order,
recording each in a `grdb_migrations` table. Already-applied migrations never
re-run. `UpgradeTests` covers this: a database built at an older schema, filled
with a task, project, tag and time block, still has all of it after migrating to
head.

### One rule keeps that true

**Never edit or rename a migration that has shipped.** Users who already ran it
will never run it again, so your change reaches new installs only, and the two
populations silently diverge. Always add a new migration instead.

`testShippedMigrationIdentifiersAreStable` fails if a shipped identifier is
renamed or removed, so this is caught in CI rather than in the field.

### Downgrading

Verified, not assumed: if someone installs a newer build and then reverts to an
older one, GRDB **does not refuse**. The old binary ignores the migration it has
never heard of and runs against the newer schema. Data is not lost.

That works today only because every migration so far has been additive. It stops
being safe the moment a migration drops or renames something an older shipped
build reads. If you ever need such a migration, bump a schema-version marker and
have the app refuse to open a database from the future.

---

## Resetting the database during development

`eraseDatabaseOnSchemaChange` is **off** by default, including in DEBUG — a
Debug build shares its database file with the installed app, so leaving it on
meant every schema change wiped real tasks. Opt in per run when it is genuinely
wanted:

```sh
CADENCE_RESET_DB=1 xcodebuild -project Cadence.xcodeproj -scheme Cadence \
  -destination 'platform=macOS' test
```

Otherwise, write a new migration.

---

## Signing

The build is **ad-hoc signed** (`CODE_SIGN_IDENTITY: "-"`). It runs fine on the
machine that built it, but Gatekeeper blocks it for anyone else until they
right-click → Open or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Cadence.app
```

To remove that friction you need a paid Apple Developer account, then:

1. Set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY: "Developer ID Application"`
   in `project.yml`.
2. Enable hardened runtime (`ENABLE_HARDENED_RUNTIME: YES`).
3. Notarise the zip with `xcrun notarytool submit --wait`, then `xcrun stapler
   staple` the app.

Note that hardened runtime restricts subprocess execution. Running an arbitrary
AI CLI will need the `com.apple.security.cs.allow-unsigned-executable-memory` /
`allow-dyld-environment-variables` exceptions, or a signed helper — worth
checking before promising a notarised build.

---

## Auto-update

Built in, no dependency. `Updater` polls
`https://api.github.com/repos/okxiaochen/Cadence/releases/latest` at most every
six hours, compares `tag_name` against `CFBundleShortVersionString`, and shows a
banner when something newer exists. **Check for Updates…** in the app menu forces
a check; Settings › Updates has the automatic toggle.

Nothing else is needed at release time: publishing a GitHub release with a
`Cadence-<version>-macOS.zip` asset attached is what makes it appear.

### What "Update & Relaunch" actually does

1. **Snapshots the database** with `VACUUM INTO`, then opens the snapshot and
   reads it back. If the snapshot cannot be verified, the update stops and
   nothing is touched.
2. Downloads the zip over TLS and unpacks it.
3. Checks the bundle identifier matches, the version matches what the release
   advertised, and that it is genuinely newer. Downgrades are refused.
4. Hands the swap to a detached script, then quits. The script waits for the
   process to exit, **moves the old bundle aside** rather than deleting it,
   installs the new one, and puts the old one back if anything fails. Verified
   both ways — a failed install leaves the working app in place.

### Why the database survives

It is not in the bundle. `~/Library/Application Support/Cadence/` is untouched by
the swap, and `UpgradeTests` covers migrating a populated old-schema database to
head with everything intact.

The risk an update really carries is the *new build's* migrations — they run
once, on data that exists only on this machine. That is what the pre-update
snapshot is for. Ten are kept, in
`~/Library/Application Support/Cadence/Backups/`, listed in Settings › Updates.

### The identity gap

Without Developer ID signing, a downloaded bundle cannot be cryptographically
tied to the author. The checks above catch a corrupt or wrong download; they do
not prove provenance. Integrity rests on TLS and GitHub. Signing and notarising
closes this, and is the main reason to bother with a paid account.
