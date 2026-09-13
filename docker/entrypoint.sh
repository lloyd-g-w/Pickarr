#!/bin/sh
# Pickarr container entrypoint.
#
# Mirrors the PUID/PGID convention used by the *arr images: when started as
# root, remap the "pickarr" user to PUID/PGID (default 1000/1000), make sure
# /data is owned by it, then drop privileges. When started with an explicit
# `user:` (non-root), just run as that user.
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
DATA_DIR="${DATA_DIR:-/data}"

if [ "$(id -u)" = "0" ]; then
  if [ "$(id -g pickarr)" != "$PGID" ]; then
    groupmod -o -g "$PGID" pickarr
  fi
  if [ "$(id -u pickarr)" != "$PUID" ]; then
    usermod -o -u "$PUID" pickarr
  fi
  mkdir -p "$DATA_DIR"
  # Only touch ownership when it is wrong, so a large volume is not rewritten
  # on every start.
  if [ "$(stat -c '%u:%g' "$DATA_DIR")" != "$PUID:$PGID" ]; then
    chown -R "$PUID:$PGID" "$DATA_DIR"
  fi
  echo "Pickarr: running as uid=$PUID gid=$PGID, data dir $DATA_DIR"
  exec gosu "$PUID:$PGID" /usr/local/bin/pickarr "$@"
else
  exec /usr/local/bin/pickarr "$@"
fi
