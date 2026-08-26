#!/bin/bash

# manual trigger for a running cron container: 'docker exec <container> backup-now'.
# it goes through cron.sh on purpose, so a manual run behaves exactly like a scheduled
# one - same environment, same lock, same notifications
exec bash /epicsoft/cron.sh
