#!/bin/sh
set -e

# The Fly volume mounts root-owned. redis:8-alpine drops to the redis user
# before writing, so AOF startup dies with:
# "Can't open or create append-only dir appendonlydir: Permission denied"
mkdir -p /data
# Fly's ext4 volume contains lost+found. Redis 8 skips its own chown when
# it sees that file, then drops to user redis and cannot create appendonlydir.
chown redis:redis /data
chmod 770 /data
export SKIP_FIX_PERMS=1

exec /usr/local/bin/docker-entrypoint.sh "$@"
