# DB Backup

This Docker image is managed and kept up to date by [epicsoft LLC](https://epicsoft.one).

Docker image for creating database backups for [MySQL](https://www.mysql.com/), [MariaDB](https://mariadb.org/) and [PostgreSQL](https://www.postgresql.org/) based on official Alpine image.

* Base image: https://hub.docker.com/_/alpine
* Dockerfile: https://gitlab.com/epicsoft-networks/dbbackup/blob/main/Dockerfile
* Repository: https://gitlab.com/epicsoft-networks/dbbackup/tree/main
* Container-Registry: https://gitlab.com/epicsoft-networks/dbbackup/container_registry
* Docker Hub: https://hub.docker.com/r/epicsoft/dbbackup

## Description

This Docker image creates database dumps for [MySQL](https://www.mysql.com/), [MariaDB](https://mariadb.org/) and [PostgreSQL](https://www.postgresql.org/).  
Depending on the configuration, the created DB dump can be compressed with [7Zip](https://www.7-zip.org/) and uploaded to an S3 storage.  
Docker Image for database backup based on official [Alpine image](https://hub.docker.com/_/alpine).

Features: 
- Create [MySQL](https://www.mysql.com/) database dump 
- Create [MariaDB](https://mariadb.org/) database dump 
- Create [PostgreSQL](https://www.postgresql.org/) database dump 
- Compress and encrypt database dump file with [7Zip](https://www.7-zip.org/)
- Upload database dump file to S3 storage
- Run the backup on a schedule inside a long running container (cron)
- Remove old backup files from the working directory (retention)
- Call a webhook after a successful or a failed backup
- Trigger a backup manually in a running cron container
- Report an unhealthy container when the backups stop working

Working direktory: `/backup`

## Modes

The image supports two modes:

- **One-shot** (default): the container creates one backup and exits. Use this when an external scheduler (host cron, Kubernetes CronJob, CI pipeline, ...) starts the container.
- **Cron**: set `CRON_SCHEDULE` to a cron expression and the container stays running and creates the backups itself.

In cron mode a failing backup does *not* stop the container — the error is logged and the next scheduled run is executed as usual. If a backup is still running when the next run is due, that run is skipped with a warning instead of running twice in parallel. All output of the scheduled backups is written to the container log (`docker logs`).

Use `TZ` to set the timezone the schedule is evaluated in — without it the schedule uses `UTC`.

## Triggering a backup manually

A running cron container can create a backup right away, which is the quickest way to check whether a new configuration actually works:

```bash
docker exec <container> backup-now
```

The manual run goes through the same code as a scheduled one - same environment, same lock, same compression, upload, retention and webhooks - and its output appears in the terminal instead of in `docker logs`. It exits with the exit code of the backup, so it can be used in a script or a pipeline. If a scheduled backup happens to be running at that moment, the manual run is skipped with a warning instead of running a second dump in parallel.

`CRON_RUN_ON_START=true` does the same thing once at container start.

## Healthcheck

The image brings its own healthcheck. It does not just look for a running cron daemon - that alone would report a healthy container while every single backup has been failing for weeks. Instead it reports unhealthy when:

- the cron daemon is gone, or
- the last backup run ended with an error, or
- `HEALTHCHECK_MAX_AGE` is set and the last successful backup is older than that

The third rule is the one that makes the check worth having, because it is the only one that notices a schedule that quietly stopped firing. Set it a little above the backup interval, so a single late run does not raise a false alarm:

```yaml
services:
  backup:
    image: epicsoft/dbbackup:latest
    environment:
      BACKUP: mariadb
      MARIADB_HOST: db
      MARIADB_USERNAME: <USERNAME>
      MARIADB_PASSWORD_FILE: /run/secrets/db_password
      CRON_SCHEDULE: "0 3 * * *"
      TZ: Europe/Berlin
      HEALTHCHECK_MAX_AGE: 26h
    secrets:
      - db_password
    volumes:
      - ./backups:/backup:rw
```

`HEALTHCHECK_MAX_AGE` accepts `m` for minutes, `h` for hours and `d` for days; a plain number is read as minutes. Until the first backup has run, the start of the container counts as the reference, so a fresh container is not reported unhealthy before its first run is genuinely overdue. A one-shot container is never reported unhealthy, since there is nothing long running to watch.

The reason for an unhealthy container is shown in `docker inspect`:

```bash
docker inspect --format '{{json .State.Health}}' <container>
```

The interval, timeout and retries of the check can be overridden per service with the `healthcheck` key in the compose file.

## Secrets from files

Every password and key can be read from a file instead of an environment variable by appending `_FILE` to the variable name and pointing it at the file. This is meant for [Docker secrets](https://docs.docker.com/engine/swarm/secrets/), Kubernetes secret mounts and comparable mechanisms, so the credential never has to appear in the container configuration.

- `MARIADB_PASSWORD_FILE`
- `MYSQL_PASSWORD_FILE`
- `PGSQL_PASSWORD_FILE`
- `COMPRESS_ENCRYPTION_PASSWORD_FILE`
- `S3_ACCESS_KEY_FILE`
- `S3_SECRET_KEY_FILE`

No password is passed on the command line, where it would be readable for every process in the container and through `docker top` on the host. For MySQL and MariaDB the dump is started with the dump is started with a `--defaults-extra-file` that is created at runtime with mode 0600 and removed again when the backup ends. That way the password is not visible in the process list of the container or in `docker top` on the host. For PostgreSQL the password is handed over in `PGPASSWORD`, and 7-Zip reads its encryption password from stdin - neither is visible there either.

A trailing newline in the file is stripped. Setting a variable and its `_FILE` counterpart at the same time is an error, as is a missing, unreadable or empty file. In cron mode the file is read again on every scheduled run.

## Retention

Old backup files in the working directory can be removed automatically after a successful backup. Two rules are available and both are off by default:

- `RETENTION_KEEP_LAST` keep the given number of newest backups
- `RETENTION_KEEP_DAYS` keep every backup that is not older than the given number of days

A backup file is removed only if **neither** rule wants to keep it. That makes `RETENTION_KEEP_LAST` a floor under `RETENTION_KEEP_DAYS`: if the backups fail for longer than `RETENTION_KEEP_DAYS`, the last working backups are still kept instead of being deleted for being too old. Using `RETENTION_KEEP_DAYS` without `RETENTION_KEEP_LAST` is possible, but the combination of both is recommended.

The cleanup only ever touches files of this backup in the working directory, that is files matching `*.<FILENAME>.sql*` with the `MARIADBDUMP_FILENAME`, `MYSQLDUMP_FILENAME` or `PGSQL_FILENAME` of the current configuration. Other files in the directory, including backups written with a different filename, are left alone. Empty files left behind by a failed dump are always removed and never count as a backup.

A dump that was aborted leaves a truncated file behind, because the shell creates the target of the redirection before the dump command fails. Such a file is removed at the end of a failed run, so it can never be mistaken for a backup. A dump that completed is kept even if a later step - compression or upload - fails.

The cleanup runs only after the dump - and if enabled, the upload - succeeded. A failed backup never deletes anything. Files that were already uploaded to S3 are not affected; use the lifecycle rules of the bucket for retention there.

## Webhooks

Two independent URLs can be called when a backup run ends:

- `WEBHOOK_SUCCESS_URL` is called after a run that completed without an error
- `WEBHOOK_FAILURE_URL` is called after a run that failed anywhere - a missing configuration value, a failing dump, a failing compression or a failing upload

The URL is used exactly as given, so they can point at two different endpoints or at the same endpoint with different query parameters:

```bash
docker run --rm \
  -e BACKUP=mysql \
  -e MYSQL_HOST=example.com \
  -e MYSQL_USERNAME=<USERNAME> \
  -e MYSQL_PASSWORD='<PASSWORD>' \
  -e WEBHOOK_SUCCESS_URL='https://example.com/hook?job=nightly&status=ok' \
  -e WEBHOOK_FAILURE_URL='https://example.com/hook?job=nightly&status=failed' \
  -v /tmp:/backup:rw \
  epicsoft/dbbackup:latest
```

`WEBHOOK_METHOD` selects how they are called and applies to both:

- `GET` (default) calls the URL and sends nothing else
- `POST` sends a JSON body describing the run, with `Content-Type: application/json`

```json
{
  "status": "success",
  "backup": "mariadb",
  "hostname": "0548b1cc0fa7",
  "database_host": "db.example.com",
  "databases": "demo",
  "started_at": "2026-08-26T05:14:28Z",
  "finished_at": "2026-08-26T05:14:31Z",
  "duration_seconds": 3,
  "exit_code": 0,
  "file_name": "20260826-051428.backup.sql.7z",
  "file_path": "/backup",
  "file_size": 817,
  "compressed": true,
  "encrypted": true,
  "s3_target": "s3://backups/nightly/20260826-051428.backup.sql.7z"
}
```

`file_size` is the size of the backup file in bytes - after compression, if that is enabled, so it is the size of the file that `file_name` names. `compressed` says whether the dump was packed with 7-Zip and `encrypted` whether that archive is password protected - the two are independent, compression without a password is possible. The body never contains a password, a key or a token. Every field that is not known yet is sent as `null`, which is what most fields look like when the run failed before the dump started. `status` is `success` or `failure` and `exit_code` is the exit code of the backup.

A webhook that cannot be reached or that answers with anything other than `2xx` is logged as a warning and does not turn a successful backup into a failed one. Each call waits at most 10 seconds and is retried twice. Because a webhook URL often contains a token, `WEBHOOK_SUCCESS_URL_FILE` and `WEBHOOK_FAILURE_URL_FILE` are available as well.

## Versions

Released through a git tag `X.Y.Z`, which publishes `X.Y.Z`, `X.Y`, `X` and moves `latest`.
Changes are listed in [CHANGELOG.md](CHANGELOG.md).

| Tag | Content |
|---|---|
| `1.2.3` | exactly this build - **use this in production** |
| `1.2` | latest patch of `1.2` - safe to follow, no behaviour changes |
| `1` | latest minor of `1` - new features, no breaking changes |
| `latest` | newest release of any version - **can change the major version without warning** |
| `develop` | current state of the `develop` branch, not for production |

> With a backup image, a silently changed behaviour is not noticed when it
> happens but when the backup is needed. Pin `X.Y.Z` or `X.Y`.

All tags are based on `alpine:latest` - build `weekly`

## Environment variables

- `BACKUP` type of database backup, one of `mysql`, `mariadb`, `pgsql`, `sqlite` ***required*** 
- `CRON_SCHEDULE` cron expression with 5 fields, for example `0 3 * * *` for a daily backup at 03:00, or a keyword such as `@daily`. A schedule that is not usable is rejected on start instead of silently never running. If empty the container creates one backup and exits (default: *empty*)
- `CRON_RUN_ON_START` create a backup immediately when the container starts, additionally to the schedule (default: `false`)
- `HEALTHCHECK_MAX_AGE` how old the last successful backup may get before the container is reported unhealthy, for example `26h`. Understands `m`, `h` and `d`, a plain number counts as minutes. If empty the healthcheck only reports a dead cron daemon and a failed run (default: *empty*)
- `TZ` timezone the cron schedule is evaluated in, for example `Europe/Berlin` (default: `UTC`)
- `WEBHOOK_METHOD` how the webhooks are called, `GET` or `POST` (default: `GET`)
- `WEBHOOK_SUCCESS_URL` URL to call after a successful backup, or `WEBHOOK_SUCCESS_URL_FILE` (default: *empty*)
- `WEBHOOK_FAILURE_URL` URL to call after a failed backup, or `WEBHOOK_FAILURE_URL_FILE` (default: *empty*)
- `RETENTION_KEEP_LAST` number of newest backups to keep in the working directory. If empty this rule is not applied (default: *empty*)
- `RETENTION_KEEP_DAYS` keep backups in the working directory that are not older than this number of days. If empty this rule is not applied (default: *empty*)
- `STAGING_DIR` directory the raw dump is written to while `COMPRESS_ENABLE` is on, before it is packed into `/backup`. Only the finished archive reaches the backup target, so an unpacked dump never lies on remote storage and cannot be caught by one of its snapshots. Must be on the container's own file system, not inside `/backup`. Without compression the dump is the result and is written to `/backup` directly, and this variable has no effect (default: `/tmp/dbbackup`)
- `COMPRESS_ENABLE` enable compression of dump with 7-Zip (default: `false`)
- `COMPRESS_OPTIONS` 7-Zip arguments for compression (default: `a -t7z -md=20 -m0=lzma2 -mx=9 -mmt=on -aoa`)
- `COMPRESS_ENCRYPTION_PASSWORD` 7-Zip password for encryption, or `COMPRESS_ENCRYPTION_PASSWORD_FILE` (default: *empty*)
- `S3_ENABLE` enable S3 upload (default: `false`)
- `S3_ACCESS_KEY` your S3 access key, or `S3_ACCESS_KEY_FILE` ***required***
- `S3_SECRET_KEY` your S3 secret key, or `S3_SECRET_KEY_FILE` ***required***
- `S3_REGION` S3 bucket region ***required*** (not required for [MinIO](https://minio.io))
- `S3_BUCKET` your S3 bucket path ***required***
- `S3_PREFIX` path prefix in your bucket (default: `backup`)
- `S3_ENDPOINT` S3 Endpoint URL without schema, for S3 Compliant APIs such as [MinIO](https://minio.io). The endpoint is always called over `https` (default: *empty*)
- `S3_FILENAME` a consistent filename to overwrite with your backup. If not set will use a timestamp.
- `S3_S3V4` set to `true` to enable Signature Version 4, required for [MinIO](https://minio.io) servers (default: `false`)

***only if `BACKUP` is `mariadb`***

- `MARIADB_HOST` database host ***required***
- `MARIADB_PORT` database port (default: `3306`)
- `MARIADB_USERNAME` database username ***required***
- `MARIADB_PASSWORD` database password, or `MARIADB_PASSWORD_FILE` ***required***
- `MARIADBDUMP_OPTIONS` dump options (default: `--verbose --hex-blob --quote-names --quick --add-drop-table --add-locks --create-options --allow-keywords --disable-keys --extended-insert --single-transaction --comments --no-tablespaces`)
- `MARIADBDUMP_ADD_OPTIONS` additional dump options (default: *empty*)
- `MARIADBDUMP_DATABASES` list of databases to backup (default: `--all-databases`)
- `MARIADBDUMP_FILENAME` name of backup file (default: `backup`)

***only if `BACKUP` is `mysql`***

- `MYSQL_HOST` database host ***required***
- `MYSQL_PORT` database port (default: `3306`)
- `MYSQL_USERNAME` database username ***required***
- `MYSQL_PASSWORD` database password, or `MYSQL_PASSWORD_FILE` ***required***
- `MYSQLDUMP_OPTIONS` dump options (default: `--verbose --hex-blob --quote-names --quick --add-drop-table --add-locks --create-options --allow-keywords --disable-keys --extended-insert --single-transaction --comments --no-tablespaces`)
- `MYSQLDUMP_ADD_OPTIONS` additional dump options (default: *empty*)
- `MYSQLDUMP_DATABASES` list of databases to backup (default: `--all-databases`)
- `MYSQLDUMP_FILENAME` name of backup file (default: `backup`)

Connecting to MySQL 8.4 and newer fails with `TLS/SSL error: self-signed certificate in certificate chain`, because the client verifies the self-signed certificate the server creates on first start. Either install a certificate the client trusts on the server, or switch the verification off:

```
MYSQLDUMP_ADD_OPTIONS=--ssl-verify-server-cert=0
```

***only if `BACKUP` is `pgsql`***

- `PGSQL_HOST` database host ***required***
- `PGSQL_PORT` database port (default: `5432`)
- `PGSQL_USERNAME` database username ***required***
- `PGSQL_PASSWORD` database password, or `PGSQL_PASSWORD_FILE` ***required***
- `PGSQL_OPTIONS` dump options (default: `--verbose`)
- `PGSQL_DATABASES` list of databases to backup (default: `--all-databases`)
- `PGSQL_FILENAME` name of backup file (default: `backup`)
- `PGSQL_VERSION` Version number of the pg-client; possible values are `17` and `18` (default: `17`)

***only if `BACKUP` is `sqlite`***

- `SQLITE_DATABASE` path to the SQLite database file inside the container, several paths separated by spaces (only with `SQLITE_MODE=dump`) ***required for `BACKUP=sqlite`***
- `SQLITE_MODE` `backup` uses the built-in online backup and writes a self-contained database file, `dump` writes SQL text (default: `backup`)
- `SQLITE_FILENAME` name of the backup file, without timestamp and extension (default: `backup`)
- `SQLITE_INTEGRITY_CHECK` run `PRAGMA integrity_check` and fail the run instead of storing an unusable backup. In `backup` mode the copy is checked, in `dump` mode the source (default: `true`)
- `SQLITE_REPORT_SIZE` additionally log the compacted size (`VACUUM INTO`) next to the file size. SQLite does not return deleted pages to the file system, so a growing file is not necessarily growing data (default: `false`)

## Installed Alpine packages

Alpine packages are installed in the current image in the latest version - https://pkgs.alpinelinux.org/packages

- bash
- mariadb-client
- mariadb-connector-c
- mysql-client
- postgresql17-client
- postgresql18-client
- sqlite
- aws-cli
- curl
- p7zip
- tzdata
- ca-certificates

## Examples

### MySQL dump

```bash
docker run --rm \
  -e BACKUP=mysql \
  -e MYSQL_HOST=example.com \
  -e MYSQL_USERNAME=<USERNAME> \
  -e MYSQL_PASSWORD='<PASSWORD>' \
  -v /tmp:/backup:rw \
  epicsoft/dbbackup:latest
```

### PostgreSQL dump with custom filename

```bash
docker run --rm \
  -e BACKUP=pgsql \
  -e PGSQL_HOST=example.com \
  -e PGSQL_PORT=5432 \
  -e PGSQL_USERNAME=<USERNAME> \
  -e PGSQL_PASSWORD='<PASSWORD>' \
  -e PGSQL_FILENAME=pg-example \
  -e PGSQL_VERSION=17 \
  -v /tmp:/backup:rw \
  epicsoft/dbbackup:latest
```

### Back up a SQLite database while the application keeps running

The database is a file, so it has to be mounted into the container, and the
container needs to be able to read a file that belongs to the application - hence
`group_add`.

```bash
docker run --rm \
  -e BACKUP=sqlite \
  -e SQLITE_DATABASE=/data/grafana.db \
  -e SQLITE_FILENAME=grafana \
  -e RETENTION_KEEP_DAYS=30 \
  -e COMPRESS_ENABLE=true \
  --group-add 472 \
  -v /srv/acc-monitoring/grafana:/data:rw \
  -v /mnt/backup/grafana:/backup:rw \
  epicsoft/dbbackup:1.0.0
```

`SQLITE_MODE=backup` is the default and the safe one while the application is
writing. A plain file copy can catch the database mid-write, and the `-wal` and
`-shm` files belonging to it are not part of the copy - the result looks fine
until it is restored.

> **Why the source is mounted `rw` and not `ro`:** a database in WAL mode cannot
> even be *read* from a read-only mount, because SQLite has to create the `-shm`
> file next to it. `:ro` works only for databases that use a rollback journal.
> The image detects the case and says so instead of failing with
> `unable to open database file`.

### Dump a database from MariaDB and compress with encryption

```bash
docker run --rm \
  -e BACKUP=mariadb \
  -e MARIADB_HOST=example.com \
  -e MARIADBDUMP_DATABASES=<DATABASE-NAME> \
  -e MARIADB_USERNAME=<USERNAME> \
  -e MARIADB_PASSWORD='<PASSWORD>' \
  -e COMPRESS_ENABLE=true \
  -e COMPRESS_ENCRYPTION_PASSWORD='<COMPRESS-PASSWORD>' \
  -v /tmp:/backup:rw \
  epicsoft/dbbackup:latest
```

### Read the database password from a file instead of an environment variable

```bash
docker run --rm \
  -e BACKUP=mysql \
  -e MYSQL_HOST=example.com \
  -e MYSQL_USERNAME=<USERNAME> \
  -e MYSQL_PASSWORD_FILE=/run/secrets/mysql_password \
  -v /path/to/mysql_password:/run/secrets/mysql_password:ro \
  -v /tmp:/backup:rw \
  epicsoft/dbbackup:latest
```

With Docker Compose and a secret the same setup looks like this:

```yaml
services:
  backup:
    image: epicsoft/dbbackup:latest
    environment:
      BACKUP: mysql
      MYSQL_HOST: example.com
      MYSQL_USERNAME: <USERNAME>
      MYSQL_PASSWORD_FILE: /run/secrets/mysql_password
      CRON_SCHEDULE: "0 3 * * *"
      TZ: Europe/Berlin
    secrets:
      - mysql_password
    volumes:
      - /tmp:/backup:rw

secrets:
  mysql_password:
    file: ./mysql_password.txt
```

### Run permanently and dump a MySQL database every night at 03:00

```bash
docker run -d --restart unless-stopped \
  -e BACKUP=mysql \
  -e MYSQL_HOST=example.com \
  -e MYSQL_USERNAME=<USERNAME> \
  -e MYSQL_PASSWORD='<PASSWORD>' \
  -e CRON_SCHEDULE='0 3 * * *' \
  -e TZ=Europe/Berlin \
  -v /tmp:/backup:rw \
  epicsoft/dbbackup:latest
```

### Dump a database from MariaDB and upload to S3

*S3 upload tested with [Wasabi](https://wasabi.com/)*

```bash
docker run --rm \
  -e BACKUP=mariadb \
  -e MARIADB_HOST=example.com \
  -e MARIADBDUMP_DATABASES=<DATABASE-NAME> \
  -e MARIADB_USERNAME=<USERNAME> \
  -e MARIADB_PASSWORD='<PASSWORD>' \
  -e S3_ENABLE=true \
  -e S3_UPLOAD_ENABLE=true \
  -e S3_ACCESS_KEY=<ACCESS-KEY> \
  -e S3_SECRET_KEY=<SECRET-KEY> \
  -e S3_BUCKET=backup \
  -e S3_PREFIX=subdirectory \
  -e S3_ENDPOINT=<ENDPOINT-WITHOUT-SCHEMA> \
  -e S3_S3V4=true \
  epicsoft/dbbackup:latest
```

## Troubleshooting

### `Access denied for user ... (using password: YES)` although the password is correct

Docker Compose replaces `$` in the values under `environment:` before the container ever sees them. A `$` in a password that is followed by a letter, an underscore or a `{` is read as the start of a variable name, and the whole reference is replaced - usually by an empty string, because that variable does not exist. Compose only mentions this in a warning line that is easy to miss, so the configuration looks correct while the container receives a shortened password:

| in the compose file | what arrives in the container |
| --- | --- |
| `abc$SECRET_TOKEN-def` | `abc-def` |
| `abc${TOKEN}-def` | `abc-def` |
| `abc$$SECRET_TOKEN-def` | `abc$SECRET_TOKEN-def` |
| `abc$?!-def` | `abc$?!-def` |

The last two rows are the reason this is easy to misdiagnose: a `$` that is followed by a character which cannot start a variable name survives untouched, so the same password may work in one place and fail in another.

To check what really arrived, compare the length with the password you configured:

```bash
docker exec <container> bash -c 'echo ${#MARIADB_PASSWORD}'
```

The robust fix is `MARIADB_PASSWORD_FILE`, `MYSQL_PASSWORD_FILE` or `PGSQL_PASSWORD_FILE` with a Docker secret, see [Secrets from files](#secrets-from-files). A file is passed through untouched, which also avoids the quoting rules of YAML. If the password has to stay in `environment:`, write every `$` as `$$`.

If the length is correct, the password is not the problem. The same error is returned when no grant matches the address the connection comes from - note the host in the error message, which is the address the database sees, not necessarily the address of the backup container:

```sql
SELECT user, host FROM mysql.user WHERE user = '<USERNAME>';
```

### `SQLite database '...' uses WAL and its directory is not writable`

The database is in WAL mode and its directory is mounted read-only. SQLite has to
create a `-shm` file next to the database **even to read it**, so a read-only
mount fails - this is a property of SQLite, not of the backup.

Mount the directory read-write:

```bash
-v /srv/app/data:/data:rw
```

Databases that use a rollback journal instead of WAL do work read-only. Which one
it is can be read from byte 18 of the file header - `1` is a rollback journal,
`2` is WAL:

```bash
dd if=/srv/app/data/app.db bs=1 skip=18 count=1 2>/dev/null | od -An -tu1
```

### `TLS/SSL error: self-signed certificate in certificate chain`

The client verifies the self-signed certificate that MySQL 8.4 and newer create on first start. See the note under the `mysql` environment variables for `MYSQLDUMP_ADD_OPTIONS=--ssl-verify-server-cert=0`.

## License

MIT License see [LICENSE](https://gitlab.com/epicsoft-networks/dbbackup/blob/main/LICENSE)

Please note that the MIT license only applies to the files created by epicsoft LLC. Other software may be licensed under other licenses.
