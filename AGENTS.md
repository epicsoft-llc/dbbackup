# AGENTS.md

Guidance for AI coding agents and contributors working in this repository.

## What this repository is

A Docker image on Alpine with a single purpose: it dumps a MySQL, MariaDB, PostgreSQL or SQLite database, optionally
compresses and encrypts the dump with 7-Zip and optionally uploads it to S3 storage. All logic is Bash in `epicsoft/`;
there is no application code and no build system. Testing goes through `test/`, not through a framework.

Configuration happens exclusively through environment variables — the complete, published list is in `README.md`. The
pipeline uploads the README as the Docker Hub description, so it is part of the release artifact, not just
documentation, and it has to stay below 25,000 bytes.

| | |
|---|---|
| **Repository** | developed on `gitlab.com/epicsoft-networks/dbbackup` (branches `develop` and `main`), mirrored to `github.com/epicsoft-llc/dbbackup` |
| **Registries** | `registry.gitlab.com/epicsoft-networks/dbbackup` and Docker Hub `epicsoft/dbbackup` |
| **Platforms** | `linux/amd64` and `linux/arm64` |

## Commands

The test environment is the standard way to verify a change:

```bash
bash test/test.sh default            # unit mariadb pgsql sqlite secrets features cron
bash test/test.sh all                # additionally mysql and s3
bash test/test.sh mariadb cron       # only these groups
bash test/test.sh --keep default     # leave the containers running afterwards
bash test/clean.sh env               # remove leftovers of an aborted run
bash test/clean.sh all               # additionally image and logs
```

Without an argument both scripts print their help and do nothing else — a test run pulls database images and takes
minutes, and `clean.sh` deletes, so neither should run by accident. The scripts in `epicsoft/` deliberately have no
such help: they are controlled by environment variables and started by the image without parameters.

`test/test.sh` builds the image, starts the databases, MinIO and a webhook receiver as containers and evaluates the
result in a named volume — only the logs under `test/.logs/` reach the host (git-ignored, only interesting after a
failure). Everything it creates carries the Docker label `dbbackup-test`; `clean.sh` cleans up by exactly that label
without having to know what ran. `test.sh` calls it itself at the end and on `INT`/`TERM`.

Two things to know when extending them:

- **`MSYS_NO_PATHCONV=1` is set at the top of both scripts.** Without it, Git Bash on Windows rewrites every argument
  that looks like a Unix path into a Windows path — `-v vol:/backup` would become a path inside the Git installation.
  The exception is the build context: it is a *host* path and is therefore passed as a relative `.` from the project
  directory.
- **Comparisons use `grep -F`, not `case` patterns.** The test password contains a backslash, which escapes the next
  character in a `case` pattern — an `assertNotContains` on a leaked password would wrongly pass.

Build and run on its own:

```bash
docker build -t dbbackup:dev .

docker run --rm \
  -e BACKUP=mysql -e MYSQL_HOST=... -e MYSQL_USERNAME=... -e MYSQL_PASSWORD='...' \
  -v /tmp:/backup:rw \
  dbbackup:dev
```

Reproduce the CI build (multi-platform, as GitLab runs it):

```bash
docker buildx build . --platform linux/amd64,linux/arm64 --build-arg IMAGE_TAG=develop
```

While iterating on the scripts, a bind mount over the copy baked into the image is faster:

```bash
docker run --rm -v "$PWD/epicsoft:/epicsoft:ro" -v /tmp:/backup:rw -e BACKUP=... dbbackup:dev
```

The cron mode is quickest to test with a one-minute schedule and `docker logs`:

```bash
docker run -d --name dbbackup-test -e CRON_SCHEDULE='* * * * *' -e CRON_RUN_ON_START=true -e BACKUP=... dbbackup:dev
docker logs -f dbbackup-test
```

On Windows (`core.autocrlf=true`) `.gitattributes` enforces LF. CRLF scripts in the image make the container die with
`$'\r': command not found` — this only affects local builds, CI checks out LF anyway.

## Architecture

`epicsoft/entrypoint.sh` is the CMD of the container and only decides between two modes:

- `CRON_SCHEDULE` empty → `exec bash backup.sh`: one backup, then the container ends.
- `CRON_SCHEDULE` set → write the crontab and `exec crond -f`. The container keeps running, and `cron.sh` starts
  `backup.sh` per run as a **separate process** (not sourced — `backup.sh` and the stages are full of `readonly`
  variables and could not run a second time in the same shell process).

`backup-now` (a symlink to `backup-now.sh` in `/usr/local/bin`) triggers a run in a running container. It deliberately
calls `cron.sh` and not `backup.sh` directly — only that way the manual run gets the same environment snapshot, the same
lock and the same notifications as a scheduled one. Changing that turns the test command into something that runs
differently from what it is supposed to test.

Three things in cron mode that are not obvious and break easily:

- **Environment:** cron jobs do *not* inherit the container environment. `entrypoint.sh` therefore writes a snapshot
  with `export -p` to `/tmp/dbbackup.env` on start (mode 0600, it contains the database and S3 passwords), which
  `cron.sh` sources first. New environment variables need nothing for that as long as they are exported — but variables
  that only come into existence at runtime are not visible in the job.
- **Logging:** busybox crond discards the output of a job (or would hand it to sendmail). The crontab line therefore
  redirects explicitly to `/proc/1/fd/1` and `/proc/1/fd/2`, so everything ends up in `docker logs`.
- **Errors do not end the container:** `cron.sh` calls `backup.sh` deliberately without `set -e`, logs a failure and
  lets crond continue — otherwise a single database outage would prevent all future backups. In addition, a `flock` on
  `/tmp/dbbackup.lock` keeps the next tick from starting a long dump a second time.

`epicsoft/backup.sh` orchestrates a single backup run. It runs with `set -e`, sources `utils.sh` for logging and then
**sources** (never executes) the stage scripts in a fixed order:

1. a dump script, selected by `BACKUP` — `mysql.sh`, `mariadb.sh`, `postresql.sh` or `sqlite.sh` (the typo in the
   file name `postresql.sh` is intended, keep it)
2. `7zip.sh`, if `COMPRESS_ENABLE` is truthy
3. `s3.sh`, if `S3_ENABLE` is truthy
4. `retention.sh`, if `RETENTION_KEEP_LAST` or `RETENTION_KEEP_DAYS` is set

Because the stages are sourced into the same shell, they share their state. That is the central contract:

- Every dump script sets `__BACKUP_FILE_NAME`, `__BACKUP_FILE_PATH`, `__BACKUP_FILE` and `__BACKUP_FILE_PATTERN`
  (mutable) at its end — that is what the following stages consume.
- `7zip.sh` **overwrites** the first three with the `.7z` file (the pattern stays, it covers `.sql` and `.sql.7z`) and
  deletes the raw dump, so `s3.sh` uploads exactly what the previous stage produced last. A new stage between dump and
  upload follows the same pattern: read, then set anew.
- The parallel `__DBBACKUP_*` variables are `readonly` snapshots of the original dump file and stay untouched by the
  compression.
- Stage scripts expect `WORKING_DIR` (`/backup`), `SCRIPT_DIR` and the functions `logInfo`/`logWarn`/`logError` to
  exist already. They cannot run on their own.

Conventions that run through all scripts:

- Boolean variables are checked with `grep -i -E "(y|yes|true|1)"` against the value, never with `== "true"`.
- Every stage validates its own required variables first and ends with `logError` and `exit 1` on an empty value.
  Because `backup.sh` sources it, that `exit` ends the whole container.
- Option strings (`*DUMP_OPTIONS`, `PGSQL_OPTIONS`, `COMPRESS_OPTIONS`) are deliberately unquoted at the call site, so
  word splitting turns them into separate arguments. `*_ADD_OPTIONS` exists so users can add options without repeating
  the defaults.
- The dump file name is always `<YYYYmmdd-HHMMSS>.<*_FILENAME>.sql`; `S3_FILENAME` only overrides the S3 object key
  (for retention by overwriting in place).
- **`assertSafeFilename "<VAR>"` is the first statement in every dump script**, before the path is built — after that
  the name already sits in a `readonly` variable. Only `[A-Za-z0-9._-]` is allowed. The value ends up in a path that
  `rm` runs on, in the retention pattern and (for SQLite) in a sqlite3 dot command; a `/`, a `*` or a quote acts
  differently in each of the three and wrongly everywhere. The function also checks for an empty value, so an extra
  `if [ -z ... ]` for the file name is redundant.
- **File modes come from `BACKUP_UMASK`**, which `backup.sh` applies once with `umask` (default `027`). Stages set no
  modes of their own — except the 0600 files for credentials, which have to be stricter.
- Every credential can be read from a file instead (`<VAR>_FILE`, the Docker secrets pattern). The responsible stage
  calls `readSecretFile "<VAR>"` from `utils.sh` before its validation; the function reads the file, exports the actual
  variable and aborts if both are set or the file is missing, unreadable or empty. A new credential needs exactly this
  one line plus `ENV <VAR>_FILE=""` in the Dockerfile.
- The MySQL/MariaDB password must **not** go back onto the command line as `--password=`: it would be readable for
  every process in the container and through `docker top` even from the host. `mysql.sh` and `mariadb.sh` instead
  create a 0600 option file with `mktemp`, fill it with `writeClientPasswordFile` and pass it as the **first** argument
  (`--defaults-extra-file=…` has to come before all other options). It is cleaned up through `registerCleanupFile`
  (see the EXIT handler below), on failure as well. In option files only `\b \t \n \r \\ \s` are escape sequences —
  that is why `writeClientPasswordFile` doubles backslashes and escapes the quote; without it, passwords containing
  `"`, `\`, `#` or spaces fail. (The official `mysql` image trips over a `"` in the root password at the same spot.)

**Where** a secret file is resolved matters: `readSecretFile` belongs in the stage scripts and explicitly *not* in
`entrypoint.sh`. The cron snapshot (`export -p`) is taken before the first backup run, so only the path ends up in
`/tmp/dbbackup.env`, never the password in plain text. Every cron run reads the secret file again.

PostgreSQL is the exception: the image installs both `postgresql17-client` and `postgresql18-client`, and
`postresql.sh` selects the binaries through the path `/usr/libexec/postgresql${PGSQL_VERSION}/`. `--all-databases` maps
to `pg_dumpall`; for an explicit list, `pg_dump` runs per database and appends each dump to the same file under an SQL
comment banner. Supporting another major version means adding the apk package to the Dockerfile *and* documenting the
value in the README. `PGSQL_PORT` defaults to `5432`.

## Webhooks and the EXIT handler

`backup.sh` installs `trap 'onBackupExit $?' EXIT` right after sourcing `utils.sh`. It is the only place that sees
*every* exit: configuration errors (`exit 1` from a stage), an aborted dump (`set -e`) and the good run.
`WEBHOOK_SUCCESS_URL` and `WEBHOOK_FAILURE_URL` are called by GET as they are — deliberately without appended
parameters, so users can point them at two endpoints or at the same URL with query parameters of their own.

That makes an invariant that is easy to miss: **stage scripts must not set a `trap … EXIT` of their own.** Bash has
one EXIT handler per shell, and a second trap silently replaces the first — the webhooks would no longer fire (or the
password option file would be left behind). Stages register their temporary files with `registerCleanupFile`
instead; `onBackupExit` removes them through `removeCleanupFiles` before it notifies.

With `WEBHOOK_METHOD=POST` a JSON body goes along, built by `buildWebhookBody` in `backup.sh`. The body **never**
contains credentials: it is built only from the `__BACKUP_*` variables, `BACKUP_STARTED_AT` and the exit code, never
from `*_PASSWORD`, `S3_*_KEY` or the webhook URL itself. Whoever adds fields has to keep that rule. The stages feed the
body through the extended handoff contract: dump scripts set `__BACKUP_DATABASE_HOST` and `__BACKUP_DATABASES`,
`7zip.sh` sets `__BACKUP_COMPRESSED`, `s3.sh` sets `__BACKUP_S3_TARGET`, and the `case` block in `backup.sh` sets the
normalized `__BACKUP_TYPE`.

`compressed` and `encrypted` are separate on purpose: `7zip.sh` sets `__BACKUP_ENCRYPTED` only in the branch that
really appends `-mhe -p…` — compressing without a password is possible. The password itself stays out, only the
boolean goes out.

After an early error almost none of this is set, so `jsonValue`/`jsonNumber` return `null` for empty values and the
body stays valid JSON. `jsonValue` escapes backslash, quote, tab, newline and carriage return and drops all other
control characters; without that, a `"` in `*_FILENAME` or a CRLF value from a `.env` file breaks the body.

Besides `EXIT`, `TERM` and `INT` are attached to the handler as well (through `exit 143`/`exit 130`), otherwise bash
dies on a signal without cleanup and without notification. Note that bash only handles a signal once the running
command returns — during a very long dump, the stop timeout of Docker can run out first and SIGKILL wins.

A failed webhook must never turn a good backup into a bad one: `callWebhook` logs an unreachable endpoint and non-2xx
responses as `[WARN]` and always returns 0. The `|| _RESULT=$?` after `curl` is needed because `set -e` would
otherwise abort in the middle of the trap.

## Incomplete files

Next to `registerCleanupFile` (always deletes) there is `registerFailureCleanupFile` (deletes only when the run fails).
The reason: `mysqldump … > file` creates the file through the redirect *before* the dump fails — what remains is a
0-byte or truncated file that looks like a backup.

The pattern is: register before the work, release with `clearFailureCleanupFile "<file>"` once it is complete; on a
failed run `onBackupExit` deletes whatever is still registered through `removeFailureCleanupFiles`. The release is the
point — a finished dump has to survive when only a later stage (compression, upload) fails. Deleting the file bluntly
at the end of every failure would lose a complete dump to an S3 outage. `clearFailureCleanupFile` releases exactly
*one* file, not the whole list — otherwise one stage could release the registration of another.

## Three traps in this Bash

- **`grep` checks line by line, validation needs `case`.** A `grep -E '^@'` or `'^[0-9]+$'` on a user value only says
  that *some* line matches. That is exactly what the crontab injection hinged on: a `CRON_SCHEDULE` containing a
  newline passed because its first line looked harmless, and the second became a crontab entry of its own. Whatever
  has to check a value as a whole belongs in a `case` pattern (`*$'\n'*`, `*[!A-Za-z0-9._-]*`), which sees the complete
  string. The same trap applies to comparisons the other way round: a backslash escapes the next character in a
  `case` pattern, and `grep -F` is the right tool there.
- **Unquoted expansions.** `*_FILENAME`, `CRON_SCHEDULE` and the like come from the user and end up in paths and tests.
  Unquoted, a space splits the path and a `*` becomes a glob — with `rm -rf` that hits the wrong files, and
  `echo ${CRON_SCHEDULE} | wc -w` suddenly counts file names instead of cron fields. The exception are the option
  strings (`*DUMP_OPTIONS`, `COMPRESS_OPTIONS`, `S3_ARGUMENTS`), which are meant to word-split.
- **`set -e` swallows your own error handling.** A `cmd; RESULT=$?; if [ $RESULT != 0 ]` is dead code, because the
  script already aborts at `cmd`. Handling the error yourself needs `cmd || RESULT=$?`.

## Healthcheck

`healthcheck.sh` deliberately does without `utils.sh`: Docker keeps only the last output line and shows it in
`docker inspect`, where timestamps and ANSI colours would only be ballast. For the same reason there are no log
functions, just plain `echo` reasons.

The actual statement lies in `HEALTHCHECK_MAX_AGE`. A check for "is crond running?" would be worthless — crond keeps
running happily while every run has failed for weeks or the schedule never fires. That is why `onBackupExit` in
`backup.sh` writes `<epoch> <exit-code>` to `/tmp/dbbackup.state` after *every* run, and the check judges age and
result. Because this happens in the EXIT handler, a run aborted by a signal is recorded as well.

Until the first run, `/tmp/dbbackup.started`, written by `entrypoint.sh`, is the reference — without it a freshly
started container with a daily backup would be unhealthy right away.

## Retention

`retention.sh` deletes old dumps from `/backup` and is the only stage that destroys data, so it is built defensively.
Four properties are deliberate and have to survive any change:

- **Keep union instead of delete union.** A file is removed only if *neither* rule wants to keep it, which makes
  `RETENTION_KEEP_LAST` the floor under `RETENTION_KEEP_DAYS`. Without that, a pure time rule deletes exactly the last
  working backup after a longer outage — the classic retention data loss.
- **Own files only.** Only what matches `__BACKUP_FILE_PATTERN` (`*.<FILENAME>.sql*`, built from the respective
  `*_FILENAME`) is deleted, never the content of `/backup` as a whole — that is a volume mounted by the user and can
  hold any files.
- **Empty files do not count.** A failed dump leaves a 0-byte file, because the shell creates the redirect target
  before `mysqldump`/`pg_dump` fails. Counted as backups, such leftovers would push real backups out under
  `RETENTION_KEEP_LAST`. They are always removed and never counted.
- **Runs only after success.** The stage comes last in `backup.sh`; because of `set -e` it is not reached after a
  failed dump or upload.

Sorting goes by file name, not by mtime — the `YYYYmmdd-HHMMSS` prefix sorts chronologically. The age uses `find -mmin`
instead of `-mtime`, because `-mtime +N` truncates to whole days and builds in an off-by-one.

The stage does not clean up S3; that is what the lifecycle rules of the bucket are for.

## Adding or changing an environment variable

It has to be touched in three places, otherwise it behaves wrongly without a sound:

1. `Dockerfile` — declare the `ENV` with its default (the scripts abort hard on empty values, so the Dockerfile is the
   actual source of the defaults)
2. the stage script — validation and use
3. `README.md` — the list of environment variables, published as the image description on Docker Hub

## Tags

| Tags | Built from | Content |
|---|---|---|
| `latest` | branch `main` (push, weekly schedule) and every release | `alpine:latest` with the newest packages |
| `develop` | branch `develop` | GitLab registry only, not for production |
| `X.Y.Z`, `X.Y`, `X` | a git tag `X.Y.Z` | frozen at release time — the tags a deployment should pin |

A release also moves `latest`, so an existing deployment on `:latest` keeps working. Versioning follows Semantic
Versioning; the rules are at the top of `CHANGELOG.md`.

## Pipeline structure (`.gitlab-ci.yml`)

| Job | Trigger | Action |
|---|---|---|
| `latest` | branch `main` (push, weekly schedule) | build and test the runner's platform, then build both platforms and push `latest` to both registries |
| `develop` | branch `develop` | the same, pushes `develop` to the GitLab registry only |
| `release` | tag `X.Y.Z` | fails unless `CHANGELOG.md` has `## [X.Y.Z] - <date>`; same build, pushes `X.Y.Z`, `X.Y`, `X` and `latest` to both registries |
| `uploadReadme` | branch `main` | README as Docker Hub description, at most 25,000 bytes |
| `github-release` | tag `X.Y.Z`, after `release` | waits for the tag on GitHub, creates the release from the `CHANGELOG.md` entry |

The test runs **before** the push, so a broken image never reaches a registry: the database clients have to start, and
one real SQLite backup is packed and encrypted with 7-Zip and the archive tested with its password. A multi-platform
build cannot be loaded locally, so the runner's own platform is built and tested first; the push build reuses those
layers from the builder cache. The `docker:dind` service runs with TLS, which buildx only takes from a Docker context —
hence `docker context create dind` before `docker buildx create`. Building `linux/arm64` on an `amd64` runner needs
QEMU (`binfmt_misc`) on the runner host.

CI variables: `DOCKER_HUB_USER`, `DOCKER_HUB_TOKEN`, `GITHUB_TOKEN` (masked, protected — so the tags have to be
protected (`*.*.*`), or the jobs see no token).

**GitHub mirror:** a push mirror in the GitLab project settings (Repository → Mirroring repositories) with its own
token, not part of the pipeline. `GITHUB_TOKEN` is only for `github-release`, which waits until the mirror has pushed
the tag. Changes are never pushed to GitHub directly; the mirror would overwrite them.

## Release checklist

- Changes go to `develop` first and reach `main` through a merge request; the tag is set on `main`.
- `CHANGELOG.md`: `## [X.Y.Z] - <date>` — the tag jobs fail without it, and `github-release` takes the notes from
  exactly that heading.
- The entry names the contained versions under `### Contents`, read from the image right before tagging:
  `docker run --rm --entrypoint sh epicsoft/dbbackup:latest -c 'cat /etc/alpine-release; mariadb-dump --version; /usr/libexec/postgresql17/pg_dump --version; /usr/libexec/postgresql18/pg_dump --version; sqlite3 --version; aws --version; 7z | sed -n 2p; apk list -I libssl3'`
- `README.md`: the `## Versions` section, and on a new minor or major version the `X.Y` in the examples.
- Tag **without `v`**: `X.Y.Z`.

## Conventions

- `.editorconfig`: 2-space indent, LF, UTF-8, final newline, trailing whitespace trimmed (except Markdown), 120 columns
  (180 for YAML, off for Markdown and shell scripts); `.gitattributes` keeps LF in the repository.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `ci:`, `chore:`).
- `apk --no-cache upgrade` comes before `apk add`: `apk add` never upgrades the packages of the base image, so their
  security fixes would only arrive with the next base image.
