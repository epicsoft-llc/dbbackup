# Troubleshooting

Known errors of the [`epicsoft/dbbackup`](https://hub.docker.com/r/epicsoft/dbbackup) image and how to fix them. The
configuration is described in the [README](https://gitlab.com/epicsoft-networks/dbbackup/-/blob/main/README.md).

## `Access denied for user ... (using password: YES)` although the password is correct

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

The robust fix is `MARIADB_PASSWORD_FILE`, `MYSQL_PASSWORD_FILE` or `PGSQL_PASSWORD_FILE` with a Docker secret, see [Secrets from files](https://gitlab.com/epicsoft-networks/dbbackup/-/blob/main/README.md#secrets-from-files). A file is passed through untouched, which also avoids the quoting rules of YAML. If the password has to stay in `environment:`, write every `$` as `$$`.

If the length is correct, the password is not the problem. The same error is returned when no grant matches the address the connection comes from - note the host in the error message, which is the address the database sees, not necessarily the address of the backup container:

```sql
SELECT user, host FROM mysql.user WHERE user = '<USERNAME>';
```

## `SQLite database '...' uses WAL and its directory is not writable`

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

## `TLS/SSL error: self-signed certificate in certificate chain`

The client verifies the self-signed certificate that MySQL 8.4 and newer create on first start. Either install a
certificate on the server that the client trusts, or switch the verification off:

```
MYSQLDUMP_ADD_OPTIONS=--ssl-verify-server-cert=0
```
