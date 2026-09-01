FROM alpine:latest

ARG IMAGE_TAG="latest"
ARG BUILD_DATE="development"
LABEL org.label-schema.name="Database Backup" \
      org.label-schema.description="Docker image for database backup based on official Alpine image" \
      org.label-schema.vendor="epicsoft LLC / Alexander Schwarz <info@epicsoft.one>" \
      org.label-schema.url="https://gitlab.com/epicsoft-networks/dbbackup" \
      org.label-schema.vcs-url="https://gitlab.com/epicsoft-networks/dbbackup/tree/main" \
      org.label-schema.version=${IMAGE_TAG} \
      org.label-schema.schema-version="1.0" \
      org.label-schema.build-date=${BUILD_DATE}

LABEL image.name="epicsoft_dbbackup" \
      image.description="Docker image for database backup based on official Alpine image" \
      maintainer="epicsoft LLC" \
      maintainer.name="Alexander Schwarz <info@epicsoft.one>" \
      maintainer.url="https://epicsoft.one/" \
      maintainer.copyright="Copyright 2024-2026 epicsoft LLC / Alexander Schwarz" \
      license="MIT"

ENV BACKUP=""
ENV BACKUP_UMASK="027"
ENV STAGING_DIR="/tmp/dbbackup"
ENV TZ="UTC"
ENV CRON_SCHEDULE=""
ENV CRON_RUN_ON_START="false"
ENV HEALTHCHECK_MAX_AGE=""
ENV MARIADB_HOST=""
ENV MARIADB_PORT="3306"
ENV MARIADB_USERNAME=""
ENV MARIADB_PASSWORD=""
ENV MARIADB_PASSWORD_FILE=""
ENV MARIADBDUMP_OPTIONS="--verbose --hex-blob --quote-names --quick --add-drop-table --add-locks --create-options --allow-keywords --disable-keys --extended-insert --single-transaction --comments --no-tablespaces"
ENV MARIADBDUMP_ADD_OPTIONS=""
ENV MARIADBDUMP_DATABASES="--all-databases"
ENV MARIADBDUMP_FILENAME="backup"
ENV MYSQL_HOST=""
ENV MYSQL_PORT="3306"
ENV MYSQL_USERNAME=""
ENV MYSQL_PASSWORD=""
ENV MYSQL_PASSWORD_FILE=""
ENV MYSQLDUMP_OPTIONS="--verbose --hex-blob --quote-names --quick --add-drop-table --add-locks --create-options --allow-keywords --disable-keys --extended-insert --single-transaction --comments --no-tablespaces"
ENV MYSQLDUMP_ADD_OPTIONS=""
ENV MYSQLDUMP_DATABASES="--all-databases"
ENV MYSQLDUMP_FILENAME="backup"
ENV PGSQL_HOST=""
ENV PGSQL_PORT="5432"
ENV PGSQL_USERNAME=""
ENV PGSQL_PASSWORD=""
ENV PGSQL_PASSWORD_FILE=""
ENV PGSQL_OPTIONS="--verbose"
ENV PGSQL_DATABASES="--all-databases"
ENV PGSQL_FILENAME="backup"
ENV PGSQL_VERSION="17"
ENV SQLITE_DATABASE=""
ENV SQLITE_MODE="backup"
ENV SQLITE_FILENAME="backup"
ENV SQLITE_INTEGRITY_CHECK="true"
ENV SQLITE_REPORT_SIZE="false"
ENV WEBHOOK_METHOD="GET"
ENV WEBHOOK_SUCCESS_URL=""
ENV WEBHOOK_SUCCESS_URL_FILE=""
ENV WEBHOOK_FAILURE_URL=""
ENV WEBHOOK_FAILURE_URL_FILE=""
ENV RETENTION_KEEP_LAST=""
ENV RETENTION_KEEP_DAYS=""
ENV COMPRESS_ENABLE="false"
ENV COMPRESS_OPTIONS="a -t7z -md=20 -m0=lzma2 -mx=9 -mmt=on -aoa"
ENV COMPRESS_ENCRYPTION_PASSWORD=""
ENV COMPRESS_ENCRYPTION_PASSWORD_FILE=""
ENV S3_ENABLE="false"
ENV S3_ACCESS_KEY=""
ENV S3_ACCESS_KEY_FILE=""
ENV S3_SECRET_KEY=""
ENV S3_SECRET_KEY_FILE=""
ENV S3_BUCKET=""
ENV S3_REGION=""
ENV S3_ENDPOINT=""
ENV S3_PREFIX="backup"
ENV S3_FILENAME=""
ENV S3_S3V4="false"

RUN apk --no-cache add bash \
                       mariadb-client \
                       mariadb-connector-c \
                       mysql-client \
                       postgresql17-client \
                       postgresql18-client \
                       sqlite \
                       aws-cli \
                       curl \
                       tzdata \
                       p7zip \
                       ca-certificates \
 && update-ca-certificates \
 && rm -rf /var/cache/apk/*

ADD epicsoft epicsoft
RUN chmod +x /epicsoft/*.sh \
 && ln -s /epicsoft/backup-now.sh /usr/local/bin/backup-now

HEALTHCHECK --interval=5m --timeout=10s --start-period=30s --retries=2 \
            CMD bash /epicsoft/healthcheck.sh

CMD [ "bash", "epicsoft/entrypoint.sh" ]
