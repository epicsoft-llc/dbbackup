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

Working direktory: `/backup`

## Versions

`latest` based on `alpine:latest` - build `weekly`

## Environment variables

- `BACKUP` type of database backup, one of `mysql`, `mariadb`, `pgsql` ***required*** 
- `COMPRESS_ENABLE` enable compression of dump with 7-Zip (default: `false`)
- `COMPRESS_OPTIONS` 7-Zip arguments for compression (default: `a -t7z -md=20 -m0=lzma2 -mx=9 -mmt=on -aoa`)
- `COMPRESS_ENCRYPTION_PASSWORD` 7-Zip password for encryption (default: *empty*)
- `S3_ENABLE` enable S3 upload (default: `false`)
- `S3_ACCESS_KEY` your S3 access key ***required***
- `S3_SECRET_KEY` your S3 secret key ***required***
- `S3_REGION` S3 bucket region ***required*** (not required for [MinIO](https://minio.io))
- `S3_BUCKET` your S3 bucket path ***required***
- `S3_PREFIX` path prefix in your bucket (default: `backup`)
- `S3_ENDPOINT` S3 Endpoint URL without schema, for S3 Compliant APIs such as [MinIO](https://minio.io) (default: *empty*)
- `S3_FILENAME` a consistent filename to overwrite with your backup. If not set will use a timestamp.
- `S3_S3V4` set to `true` to enable Signature Version 4, required for [MinIO](https://minio.io) servers (default: `false`)

***only if `BACKUP` is `mariadb`***

- `MARIADB_HOST` database host ***required***
- `MARIADB_PORT` database port (default: `3306`)
- `MARIADB_USERNAME` database username ***required***
- `MARIADB_PASSWORD` database password ***required***
- `MARIADBDUMP_OPTIONS` dump options (default: `--verbose --hex-blob --quote-names --quick --add-drop-table --add-locks --create-options --allow-keywords --disable-keys --extended-insert --single-transaction --comments --no-tablespaces`)
- `MARIADBDUMP_ADD_OPTIONS` additional dump options (default: *empty*)
- `MARIADBDUMP_DATABASES` list of databases to backup (default: `--all-databases`)
- `MARIADBDUMP_FILENAME` name of backup file (default: `backup`)

***only if `BACKUP` is `mysql`***

- `MYSQL_HOST` database host ***required***
- `MYSQL_PORT` database port (default: `3306`)
- `MYSQL_USERNAME` database username ***required***
- `MYSQL_PASSWORD` database password ***required***
- `MYSQLDUMP_OPTIONS` dump options (default: `--verbose --hex-blob --quote-names --quick --add-drop-table --add-locks --create-options --allow-keywords --disable-keys --extended-insert --single-transaction --comments --no-tablespaces`)
- `MYSQLDUMP_ADD_OPTIONS` additional dump options (default: *empty*)
- `MYSQLDUMP_DATABASES` list of databases to backup (default: `--all-databases`)
- `MYSQLDUMP_FILENAME` name of backup file (default: `backup`)

***only if `BACKUP` is `pgsql`***

- `PGSQL_HOST` database host ***required***
- `PGSQL_PORT` database port (default: `5433`)
- `PGSQL_USERNAME` database username ***required***
- `PGSQL_PASSWORD` database password ***required***
- `PGSQL_OPTIONS` dump options (default: `--verbose`)
- `PGSQL_DATABASES` list of databases to backup (default: `--all-databases`)
- `PGSQL_FILENAME` name of backup file (default: `backup`)
- `PGSQL_VERSION` Version number of the pg-client; possible values are `15`, `16`, and `17` (default: `16`)

## Installed Alpine packages

Alpine packages are installed in the current image in the latest version - https://pkgs.alpinelinux.org/packages

- bash
- mariadb-client
- mariadb-connector-c
- mysql-client
- postgresql16-client
- aws-cli
- p7zip
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

## License

MIT License see [LICENSE](https://gitlab.com/epicsoft-networks/dbbackup/blob/main/LICENSE)

Please note that the MIT license only applies to the files created by epicsoft LLC. Other software may be licensed under other licenses.
