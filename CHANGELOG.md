# Changelog

All notable changes to this image.

Versions follow [Semantic Versioning](https://semver.org/):

| Part | Raised when |
|---|---|
| **MAJOR** | an existing configuration stops working — a removed or renamed environment variable, a changed file name pattern, changed behaviour of a stage |
| **MINOR** | functionality is added without requiring a change to an existing configuration — a new database, a new optional variable |
| **PATCH** | a fix or a package update without a change in behaviour |

**A release is a git tag `X.Y.Z`.** CI builds `X.Y.Z`, `X.Y`, `X` from it and
moves `latest`.

> ⚠️ **Use `X.Y.Z` or `X.Y` in production, not `latest`.** `latest` changes the
> major version without warning, and with a backup image a changed behaviour is
> not noticed when it happens but when the backup is needed.

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
