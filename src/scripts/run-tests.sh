#!/usr/bin/env bash
# run-tests.sh — Included by src/commands/run-tests.yml. Runs
# `composer run prestaflow:json:file`; a non-zero exit is surfaced but does not
# abort the job (failures are reported through the API + PR comment).
set -euo pipefail
if [ ! -f composer.json ]; then
  echo "run-tests: no composer.json — skipping"; exit 0
fi
if ! command -v composer >/dev/null 2>&1; then
  echo "run-tests: composer not installed — use install-deps with install_composer=true or a composer-capable executor"
  exit 1
fi

# With Flashlight, the flashlight command merged the PRESTAFLOW_* job variables
# into .env.local. They are removed from composer's environment, or phpdotenv
# (immutable) would skip the file's value for them (src/runner in the Action).
STRIP=()
KEYS_FILE="$PWD/.prestaflow-flashlight/dotenv-keys"
if [ -f "$KEYS_FILE" ]; then
  while IFS= read -r key; do
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then STRIP+=(-u "$key"); fi
  done < "$KEYS_FILE"
fi

echo "run-tests: composer run prestaflow:json:file (suites=${PRESTAFLOW_SUITES:-<all>})"
set +e
env ${STRIP[@]+"${STRIP[@]}"} composer run prestaflow:json:file
RC=$?
set -e
if [ $RC -ne 0 ]; then
  echo "run-tests: composer exited $RC — parsing/uploading results anyway"
fi
