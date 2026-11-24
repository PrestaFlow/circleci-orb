#!/usr/bin/env bash
# flashlight-restore.sh — Included by src/commands/flashlight-restore.yml.
# Put the repository's .env.local back after a Flashlight run (or remove the
# generated one when there was none). Mirrors DotenvHandle.restore in the
# GitHub Action's src/flashlight/dotenv.ts.
#
# Idempotent and best-effort: push runs it with when: always, so it also runs
# when the tests or the upload failed.
set -uo pipefail

WORKSPACE="$PWD"
STATE_DIR="$WORKSPACE/.prestaflow-flashlight"
ENV_LOCAL="$WORKSPACE/.env.local"

if [ -f "$STATE_DIR/env.local.orig" ]; then
  if cp "$STATE_DIR/env.local.orig" "$ENV_LOCAL"; then
    rm -f "$STATE_DIR/env.local.orig"
    echo "flashlight: restored the repository's .env.local"
  else
    echo "flashlight: WARNING: could not restore $ENV_LOCAL (backup kept at $STATE_DIR/env.local.orig)" >&2
  fi
elif [ -f "$STATE_DIR/env.local.created" ]; then
  rm -f "$ENV_LOCAL" "$STATE_DIR/env.local.created"
  echo "flashlight: removed the generated .env.local"
fi
rm -f "$STATE_DIR/dotenv-keys"
exit 0
