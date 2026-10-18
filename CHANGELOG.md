# Changelog

All notable changes to this image.

Versions follow [Semantic Versioning](https://semver.org/):

| Part | Raised when |
|---|---|
| **MAJOR** | an existing configuration stops working — a removed or renamed environment variable, a changed file name pattern, changed behaviour of a stage |
| **MINOR** | functionality is added without requiring a change to an existing configuration — a new database, a new optional variable |
| **PATCH** | a fix or a package update without a change in behaviour |

**A release is a git tag `X.Y.Z`.** CI builds `X.Y.Z`, `X.Y`, `X` from it for
`linux/amd64` and `linux/arm64`, moves `latest` and creates the GitHub release
from the entry below. Each release entry names the contained versions.

> ⚠️ **Use `X.Y.Z` or `X.Y` in production, not `latest`.** `latest` changes the
> major version without warning, and with a backup image a changed behaviour is
> not noticed when it happens but when the backup is needed.

---

## [2.0.2] - 2026-10-18

OpenSSL `3.5.9` with its security fixes. Nothing changes in behaviour.

### Contents

- MariaDB client `11.8.8`, PostgreSQL clients `17.11` and `18.6`, SQLite
`3.53.4`, AWS CLI `2.34.63`, 7-Zip `26.01`, OpenSSL `3.5.9`, Alpine `3.24.2`

### Security

- **The packages of the base image are upgraded as well.** `apk add` only
installs what is missing and left the packages that come with `alpine:latest`
at the state of its last point release - 2.0.1 still shipped OpenSSL `3.5.8`,
although Alpine `3.24` already offered `3.5.9`, a security release whose most
severe fix is rated High. The build runs `apk upgrade` first now.

---

## [2.0.1] - 2026-10-18

Package updates, and a pipeline that tests the image before it publishes it.
Nothing changes in behaviour.

### Contents

- MariaDB client `11.8.8`, PostgreSQL clients `17.11` and `18.6`, SQLite
`3.53.4`, AWS CLI `2.34.63`, 7-Zip `26.01`, Alpine `3.24.2`

### Changed

- Rebuilt on Alpine `3.24.2`, with curl `8.22.0`, OpenSSL `3.5.8` and Python
`3.14.8` among others - 2.0.0 had Alpine `3.24.1`, curl `8.21.0`, OpenSSL
`3.5.7` and Python `3.14.7`.
- **Every image is tested before it is pushed.** The database clients have to
start, and one real backup has to succeed: a SQLite database, packed and
encrypted with 7-Zip, the archive tested with its password. A broken build no
longer reaches a registry.
- The repository is mirrored to GitHub (`epicsoft-llc/dbbackup`), and every
release is published there as a GitHub release with its entry from this file.
- The troubleshooting section moved from the README to `TROUBLESHOOTING.md`.

### Fixed

- **The build failed on runners whose `docker:dind` uses TLS** - buildx did not
reach the daemon. It gets the connection through a Docker context now.
- **The image description on Docker Hub was cut off** at 25,000 characters, in
the middle of the troubleshooting section. The README is below the limit again,
and the pipeline stops instead of publishing a cut-off text.
- README: the S3 example set `S3_UPLOAD_ENABLE`, a variable the image does not
know; the changelog link was relative and broke on Docker Hub; the examples use
`2.0` instead of `latest`, as the README itself recommends.

---

## [2.0.0] - 2026-09-01

A security release. Values that used to be taken as given are now checked, and
the backup file is no longer created world readable. **The file mode changes
for every installation, and some file names that were accepted before are
not any more** — see *Breaking* at the end.

### Added

- **`BACKUP_UMASK`** — file mode mask for everything a run writes: dump,
archive and staging directory (default `027`, that is `0640` for files and
`0750` for directories).
- `STAGING_DIR` is declared in the image now. Its default lived only inside the
script, so `docker inspect` did not list it among the settings. Value and
behaviour are unchanged.

### Fixed

- **The `POST` webhook body stays valid JSON.** A carriage return in a value
was passed through raw, and a raw control character inside a JSON string makes
the whole body invalid — so the receiver rejected exactly the notification the
run existed to send. Not an exotic case: a `.env` file or a CI variable with
CRLF line endings puts one into `MYSQL_HOST` without anyone noticing. Return is
escaped now, and the remaining control characters, which have no place in a
host name or a file name, are dropped. The values this affects are the ones
that reach the body unvalidated: database host, database list, S3 target.
- **A failing `SQLITE_REPORT_SIZE` no longer deletes the backup it just
reported on.** The report runs `VACUUM INTO` against the source database, which
fails on a malformed one — and it ran before the finished backup was released
from the cleanup that removes incomplete files. A complete backup was then
deleted, logged as "Removing incomplete file", by a diagnostic that is purely
informational. The file is released as soon as the backup is written now.
- **A failed SQLite integrity check says so now.** `sqlite3` exits non-zero on a
corrupted database, and `set -e` ended the run on that exit before the error
message was reached — the log simply stopped after "integrity check starting".
The run failed either way, so no unusable backup was ever stored, but the
reason was missing. The exit code is part of the message now.
- The README documents SQLite, which has been a supported `BACKUP` type since
1.0.0 but was missing from the description and the feature list — the same text
that is published as the image description on Docker Hub.
- `WEBHOOK_SUCCESS_URL_FILE` and `WEBHOOK_FAILURE_URL_FILE` are listed among
the variables that can be read from a file. They worked, they were just not in
that list.

### Security

- **A `CRON_SCHEDULE` can no longer add a line to the crontab.** The schedule
is written into `/etc/crontabs/root` as it is, so a value containing a newline
did not produce a broken schedule but a second crontab entry, which crond ran
as root. The field count alone did not catch it: any value beginning with `@`
skipped that check entirely. The value now has to be a single line, may only
contain the characters a schedule consists of, and an `@` keyword is matched
against the list crond actually knows.
- **`MARIADBDUMP_FILENAME`, `MYSQLDUMP_FILENAME`, `PGSQL_FILENAME` and
`SQLITE_FILENAME` are restricted to letters, digits, `.`, `_` and `-`.** The
value went into the path of the dump unchecked, and that path is written to and
removed with `rm`, so a `/` in it reached files outside `/backup`. A `*` in it
widened the retention pattern onto files that do not belong to this backup.
`PGSQL_FILENAME` was not checked for being empty at all. The name is now
checked before the path is built from it.
- **The SQLite backup target is escaped for the `sqlite3` dot command.** The
target was placed in `.backup '<path>'`, a string `sqlite3` parses itself,
where shell quoting does not reach — a single quote in the path ended the
argument. The same applies to the `VACUUM INTO` of `SQLITE_REPORT_SIZE`, which
is SQL and escapes differently. Both are escaped for their own syntax now.
- **The backup is no longer created world readable.** A dump is the database in
plain text and it stays on the backup volume after the container is gone, where
it used to be mode `0644` — readable for everyone who can enter the mount. See
`BACKUP_UMASK` above.

### Breaking

Four things behave differently than before:

| Setting | Now | Was |
|---|---|---|
| the mode of every backup file | `0640`, set `BACKUP_UMASK=022` for the old behaviour | `0644`, readable for everyone |
| a `*_FILENAME` with a space, `/`, `*` or a quote | rejected on start | a space worked and named the file that way, a `/` wrote the dump outside `/backup` |
| `CRON_SCHEDULE` over several lines | rejected on start | ran the second line as a crontab entry of its own |
| `CRON_SCHEDULE` with an unknown `@` keyword, for example `@5min` | rejected on start | accepted, but never ran a backup |

The first two are what makes this a major version: the file mode changes for
everyone, and a file name that worked stops working. The two `CRON_SCHEDULE`
rows only affect setups that were not producing backups anyway - but a
container that used to stay up now exits, which an orchestrator will notice.

Nothing else changes: file name pattern, backup location and the dump,
compress, S3, retention, webhook and healthcheck stages behave exactly as
before.

---

## [1.1.0] - 2026-08-31

### Added

- **`STAGING_DIR`** — directory the raw dump is written to while compression is
enabled (default `/tmp/dbbackup`). It has to be on the container's own file
system, not inside `/backup`.

### Changed

- **With `COMPRESS_ENABLE` on, the raw dump is staged on the container's own
file system and only the finished archive is written to `/backup`.** It used to
be written into `/backup` and packed there. `/backup` is normally a mount of
remote storage that keeps snapshots of its own, and a snapshot taken while the
unpacked dump was still lying there kept a copy that the `rm` at the end of the
compress stage could no longer reach.
- A failing compress stage now removes the staged dump as well, so no unpacked
dump survives a broken run.
- The SQLite size report writes its `VACUUM INTO` file to the staging directory
instead of the backup target.

Without compression nothing changes: the dump is the result and goes to
`/backup` directly. **No configuration change is required** — file name, file
location and the retention, S3 and webhook stages all see the same result as
before.

---

## [1.0.0] - 2026-08-28

First versioned release. The image existed before this, published as `latest`
from `main` and `develop` from `develop`; individual builds cannot be told apart
afterwards. **That is the reason for the versioning.**

### Added

- **SQLite as the fourth database** (`BACKUP=sqlite`). Configured through
  `SQLITE_DATABASE` — a file path instead of host, port, user and password.
  Two modes:
  - `SQLITE_MODE=backup` (default) uses the built-in online backup (`.backup`)
    and writes a self-contained database file. A plain file copy is **not** safe
    while the application is running: it can catch the database mid-write, and
    the `-wal` and `-shm` files belonging to it are not part of the copy. A
    `.backup` copy needs neither of them back.
  - `SQLITE_MODE=dump` writes SQL text and can put several databases into one
    file, with the same comment banner per database as PostgreSQL. `.backup`
    produces one binary file per database and binaries cannot be concatenated,
    so several databases are rejected in `backup` mode instead of silently
    keeping only the last one.
- **`SQLITE_INTEGRITY_CHECK`** (default `true`) runs `PRAGMA integrity_check`
  and fails the run instead of storing an unusable backup. In `backup` mode the
  **copy** is checked — that is the file a restore would use; in `dump` mode the
  **source**, because a dump of a damaged database produces damaged SQL without
  failing. SQLite is the only one of the four databases where such a check is a
  single cheap command.
- **`SQLITE_REPORT_SIZE`** (default `false`) logs the compacted size
  (`VACUUM INTO`) next to the file size. SQLite does not return deleted pages to
  the file system, so without the comparison fragmentation reads as growth.
- **A diagnostic for WAL databases on a read-only mount.** A database in WAL
  mode cannot even be *read* from a read-only mount — SQLite has to create the
  `-shm` file next to it. `sqlite3` only says `unable to open database file`,
  which points at the file instead of at the mount. The stage now detects the
  case from the file header and names the cause and the fix. Databases without
  WAL do work read-only.
- Alpine package `sqlite`.
- **Versioned releases** through git tags, and this file.

### Changed

- `.gitlab-ci.yml` has a `release` job for tags `X.Y.Z`. The existing jobs for
  `main` (`latest`) and `develop` (`develop`) are unchanged, so a deployment
  running on `latest` keeps working — the point of the version tags is that
  nobody *has to* use `latest`, not that it disappears.

### Verified

Built and run against a real SQLite database, not only checked for syntax:

| Case | Result |
|---|---|
| WAL database, source mounted read-write | backup and integrity check pass |
| WAL database, source mounted read-only | rejected with a named cause |
| Non-WAL database, source mounted read-only | passes |
| Two databases in `backup` mode | rejected |
| Missing database file | rejected |
| Damaged database | integrity check fails and the unusable copy is removed |
| `dump` mode with two databases | one SQL file with a banner per database |
| Compression and retention | 7-Zip and `RETENTION_KEEP_LAST` apply as for the other databases |
| **Restore** from the `.backup` copy, from the `.7z` and from the SQL dump | all three return the original rows; the `.backup` copy needs no `-wal`/`-shm` |
