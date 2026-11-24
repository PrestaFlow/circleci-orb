#!/usr/bin/env bash
# flashlight.sh — Boot a PrestaShop Flashlight container that binds the
# workspace at the right in-container path. Included by
# src/commands/flashlight.yml. Mirrors src/flashlight/ from the GitHub Action
# (compose-template, docker, mount, install-module, ps-version, dotenv).
#
# REQUIRES the machine executor (Docker bind mounts from the job workspace are
# not supported inside setup_remote_docker).
#
# State shared with run-tests.sh and flashlight-restore.sh lives in
# $WORKSPACE/.prestaflow-flashlight/:
#   compose.yml        the stack
#   dotenv-keys        keys written to .env.local, stripped from composer's env
#   env.local.orig     the repository's own .env.local, put back after the run
#   env.local.created  marker: .env.local did not exist, removed after the run
# (by the flashlight-restore command, which push runs with when: always)
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "flashlight: docker CLI not available — use the prestaflow/machine executor"
  exit 1
fi

# Flashlight image tag (9.0.0, 8.2.8-nginx, latest…). Never passed to the
# library as is: see resolve_ps_version below.
IMAGE_TAG="${PRESTAFLOW_FLASHLIGHT_TAG:-latest}"
MODE="${PRESTAFLOW_FLASHLIGHT_MOUNT:-auto}"
INIT_SCRIPTS="${PRESTAFLOW_FLASHLIGHT_INIT_SCRIPTS:-}"
INSTALL_MODULE="${PRESTAFLOW_FLASHLIGHT_INSTALL_MODULE:-true}"
WORKSPACE="$PWD"
WORKSPACE_BASENAME=$(basename "$WORKSPACE")
INSTALL_MODULE_HINT='flashlight_install_module: false'
PS_VERSION_HINT='Set PRESTAFLOW_PS_VERSION in the job environment, or use a versioned ps_version (e.g. 8.2.8-nginx).'
GENERATOR='PrestaFlow/circleci-orb'

warn() { echo "flashlight: WARNING: $*" >&2; }

# --- mount resolution (mirrors src/flashlight/mount.ts) ---
COMPOSER_NAME=""
COMPOSER_TYPE=""
if [ -f "$WORKSPACE/composer.json" ] && command -v jq >/dev/null 2>&1; then
  COMPOSER_NAME=$(jq -r '.name // ""' "$WORKSPACE/composer.json" 2>/dev/null || echo "")
  COMPOSER_TYPE=$(jq -r '.type // ""' "$WORKSPACE/composer.json" 2>/dev/null || echo "")
fi

# Prefer the short name (after the vendor slash) when composer.name is "vendor/name".
NAME="$WORKSPACE_BASENAME"
if [ -n "$COMPOSER_NAME" ]; then
  case "$COMPOSER_NAME" in
    */*) NAME="${COMPOSER_NAME##*/}" ;;
    *)   NAME="$COMPOSER_NAME" ;;
  esac
fi

case "$MODE" in
  root)
    CONTAINER_PATH="/var/www/html"
    ;;
  modules)
    CONTAINER_PATH="/var/www/html/modules/${NAME}"
    ;;
  themes)
    CONTAINER_PATH="/var/www/html/themes/${NAME}"
    ;;
  auto)
    case "$COMPOSER_TYPE" in
      prestashop-module) CONTAINER_PATH="/var/www/html/modules/${NAME}" ;;
      prestashop-theme)  CONTAINER_PATH="/var/www/html/themes/${NAME}" ;;
      *)
        CONTAINER_PATH="/var/www/html/modules/${WORKSPACE_BASENAME}"
        echo "flashlight: composer.json missing or type unknown — defaulting to $CONTAINER_PATH. Set flashlight_mount to override."
        ;;
    esac
    ;;
  *)
    echo "flashlight: invalid mount mode '$MODE' (expected auto|root|modules|themes)"
    exit 1
    ;;
esac

echo "flashlight: mounting $WORKSPACE at $CONTAINER_PATH (mode=$MODE, image $IMAGE_TAG)"

# --- init scripts path validation ---
INIT_SCRIPTS_HOST=""
if [ -n "$INIT_SCRIPTS" ]; then
  case "$INIT_SCRIPTS" in
    /*) INIT_SCRIPTS_HOST="$INIT_SCRIPTS" ;;
    *)  INIT_SCRIPTS_HOST="$WORKSPACE/$INIT_SCRIPTS" ;;
  esac
  if [ ! -d "$INIT_SCRIPTS_HOST" ]; then
    echo "flashlight: flashlight_init_scripts path does not exist or is not a directory: $INIT_SCRIPTS_HOST"
    exit 1
  fi
  echo "flashlight: mounting init-scripts from $INIT_SCRIPTS_HOST → /tmp/init-scripts (ro)"
fi

# --- port pick (8000, 8001, 8002 in order) ---
PORT=""
for p in 8000 8001 8002; do
  if ! (echo >"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    PORT="$p"; break
  fi
done
[ -z "$PORT" ] && { echo "flashlight: no free port among 8000..8002"; exit 1; }

# --- compose file (matches src/flashlight/compose-template.ts) ---
STATE_DIR="$WORKSPACE/.prestaflow-flashlight"
mkdir -p "$STATE_DIR"
COMPOSE_FILE="$STATE_DIR/compose.yml"

EXTRA_VOLUME=""
if [ -n "$INIT_SCRIPTS_HOST" ]; then
  EXTRA_VOLUME="      - ${INIT_SCRIPTS_HOST}:/tmp/init-scripts:ro"
fi

cat >"$COMPOSE_FILE" <<YAML
services:
  prestashop:
    image: prestashop/prestashop-flashlight:${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    ports:
      - "${PORT}:80"
    volumes:
      - ${WORKSPACE}:${CONTAINER_PATH}
${EXTRA_VOLUME}
    environment:
      PS_DOMAIN: localhost:${PORT}
      DEBUG_MODE: 0
      INIT_ON_RESTART: 0

  mysql:
    image: mariadb:lts
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect"]
      interval: 10s
      timeout: 10s
      retries: 5
    environment:
      MYSQL_USER: prestashop
      MYSQL_PASSWORD: prestashop
      MYSQL_ROOT_PASSWORD: prestashop
      MYSQL_DATABASE: prestashop
YAML

echo "flashlight: starting stack via docker compose"
docker compose -f "$COMPOSE_FILE" up -d

# --- wait for the shop (mirrors waitForShop in src/flashlight/docker.ts) ---
# The front answers as soon as the web server is up, before the post-install
# scripts are done. The admin folder is renamed to the fixed admin-dev, which
# redirects (302) to the login page once PrestaShop is really serving.
URL="http://localhost:${PORT}"
READY_URL="${URL}/admin-dev/"
DEADLINE=$(( $(date +%s) + 240 ))
CODE="000"
READY=false
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$READY_URL" || echo "000")
  if [ "$CODE" = "302" ] || [ "$CODE" = "200" ]; then
    echo "flashlight: ready at $URL ($READY_URL answered HTTP $CODE)"
    READY=true
    break
  fi
  sleep 2
done

if [ "$READY" != "true" ]; then
  echo "flashlight: not ready after 240s: $READY_URL never answered 302/200 (last status: $CODE) — dumping logs"
  docker compose -f "$COMPOSE_FILE" logs || true
  exit 1
fi

shop_exec() {
  docker compose -f "$COMPOSE_FILE" exec -T "$@"
}

# --- module install (mirrors src/flashlight/install-module.ts) ---
# Only a composer prestashop-module mounted under modules/. On an already
# installed module PrestaShop runs an upgrade and reports the same success
# message. The exit code is not reliable (8.1 and 9.0 exit 0 on failure), so
# success is read from the output. A failure only warns.
MODULE_NAME=""
if [ "$INSTALL_MODULE" = "true" ] && [ "$COMPOSER_TYPE" = "prestashop-module" ]; then
  case "$CONTAINER_PATH" in
    /var/www/html/modules/*) MODULE_NAME="${CONTAINER_PATH#/var/www/html/modules/}" ;;
  esac
  if ! [[ "$MODULE_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    MODULE_NAME=""
  fi
fi
if [ -n "$MODULE_NAME" ]; then
  echo "flashlight: installing module $MODULE_NAME (disable with $INSTALL_MODULE_HINT)"
  INSTALL_OUTPUT=$(shop_exec -w /var/www/html prestashop php bin/console prestashop:module install "$MODULE_NAME" 2>&1 || true)
  printf '%s\n' "$INSTALL_OUTPUT"
  if ! printf '%s' "$INSTALL_OUTPUT" | grep -qi 'succeeded'; then
    warn "module $MODULE_NAME was not installed in Flashlight. Set $INSTALL_MODULE_HINT to skip this step (e.g. if an init-script installs it)."
  fi
fi

# --- PrestaShop version (mirrors src/flashlight/ps-version.ts) ---
# prestaflow/php-library only parses a bare version (1.7.8.11, 8.2.8) and fails
# the whole run on anything else, so the image tag is never passed as is.
is_bare_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

# 8.2.8-nginx → 8.2.8, 1.7.8.11-7.4-fpm-alpine-nginx → 1.7.8.11, latest → ''.
ps_version_from_tag() {
  local tag="$1"
  tag="${tag#"${tag%%[![:space:]]*}"}"
  tag="${tag%"${tag##*[![:space:]]}"}"
  if [[ "$tag" =~ ^([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)(-|$) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Last non-blank line of a command run in the shop container, '' when it fails.
shop_last_line() {
  local out
  out=$(shop_exec prestashop "$@" 2>/dev/null || true)
  out=$(printf '%s\n' "$out" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n 1)
  printf '%s' "${out//[[:space:]]/}"
}

# Fallback for an image without PS_VERSION: releases up to 9.1 declare it in AppKernel.
READ_APPKERNEL_PHP='echo preg_match("/const VERSION = '"'"'([0-9.]+)'"'"'/", (string) @file_get_contents("/var/www/html/app/AppKernel.php"), $m) ? $m[1] : "";'

# Version from the tag, else from the shop (Flashlight images declare it in
# their PS_VERSION variable; latest is 9.2.1 at the time of writing). Empty
# when neither says: PRESTAFLOW_PS_VERSION is then left to the user.
resolve_ps_version() {
  local v
  v=$(ps_version_from_tag "$IMAGE_TAG")
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  v=$(shop_last_line printenv PS_VERSION)
  if ! is_bare_version "$v"; then
    v=$(shop_last_line php -r "$READ_APPKERNEL_PHP")
  fi
  if is_bare_version "$v"; then
    echo "flashlight: image $IMAGE_TAG: PrestaShop $v read from the shop" >&2
    printf '%s' "$v"
    return
  fi
  warn "could not tell the PrestaShop version of Flashlight image \"$IMAGE_TAG\": PRESTAFLOW_PS_VERSION is not set by $GENERATOR. $PS_VERSION_HINT"
}

PS_VERSION=$(resolve_ps_version)

# --- .env.local (mirrors src/flashlight/dotenv.ts) ---
# The library reads its settings from $_ENV, filled by phpdotenv from the first
# existing file among .env.local and .env (immutable: a key already present in
# $_SERVER/$_ENV is never loaded from the file). Under variables_order=GPCS a
# PRESTAFLOW_* variable of the job reaches $_SERVER but not $_ENV, so it is
# invisible to libraries before 1.9 and blocks the same key from the file.
# Hence everything goes into one .env.local, and the run-tests command strips those keys
# from composer's environment. Layers, from the lowest to the highest priority
# (in one file, a later assignment wins):
#   Flashlight default accounts < user .env.local/.env < Flashlight URLs/version < job variables.

# Encode a value for phpdotenv: single quotes are fully literal; values holding
# a single quote or a line break use double quotes with phpdotenv's escapes.
dotenv_value() {
  local v="$1"
  if [[ "$v" != *"'"* && "$v" != *$'\n'* && "$v" != *$'\r'* ]]; then
    printf "'%s'" "$v"
    return
  fi
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//\$/\\\$}
  v=${v//$'\r'/\\r}
  v=${v//$'\n'/\\n}
  printf '"%s"' "$v"
}

# The CI integration's own settings, outputs and secrets are PRESTAFLOW_* too:
# they are not library settings and never go into the file.
is_integration_var() {
  case "$1" in
    PRESTAFLOW_TOKEN|PRESTAFLOW_API_URL|PRESTAFLOW_PROJECT_ID|PRESTAFLOW_EXECUTE|PRESTAFLOW_SUITES) return 0 ;;
    PRESTAFLOW_FLASHLIGHT|PRESTAFLOW_FLASHLIGHT_*) return 0 ;;
    PRESTAFLOW_MR_COMMENT|PRESTAFLOW_PR_COMMENT|PRESTAFLOW_PR_FORCE_MODE) return 0 ;;
    PRESTAFLOW_UPLOAD_ARTIFACTS|PRESTAFLOW_VISUAL|PRESTAFLOW_WORKSPACE) return 0 ;;
    PRESTAFLOW_COMPONENT_REPO|PRESTAFLOW_COMPONENT_REF|PRESTAFLOW_INSTALL_COMPOSER) return 0 ;;
    PRESTAFLOW_REPORT_ID|PRESTAFLOW_REPORT_URL|PRESTAFLOW_STATUS) return 0 ;;
    PRESTAFLOW_PASSED|PRESTAFLOW_FAILED|PRESTAFLOW_SKIPPED|PRESTAFLOW_TOTAL|PRESTAFLOW_DURATION_MS) return 0 ;;
    *_TOKEN|*_TOKEN_VALUE) return 0 ;;
  esac
  return 1
}

ENV_LOCAL="$WORKSPACE/.env.local"
ENV_FILE="$WORKSPACE/.env"
KEYS_FILE="$STATE_DIR/dotenv-keys"

# Back up the repository's .env.local once: a second run in the same job must
# not back the generated file up over the original.
if [ ! -f "$STATE_DIR/env.local.orig" ] && [ ! -f "$STATE_DIR/env.local.created" ]; then
  if [ -f "$ENV_LOCAL" ]; then
    cp "$ENV_LOCAL" "$STATE_DIR/env.local.orig"
  else
    : > "$STATE_DIR/env.local.created"
  fi
fi

# Mirror phpdotenv: when .env.local exists, .env is never read.
USER_FILE=""
USER_SOURCE=""
if [ -f "$STATE_DIR/env.local.orig" ]; then
  USER_FILE="$STATE_DIR/env.local.orig"; USER_SOURCE=".env.local"
elif [ -f "$ENV_FILE" ]; then
  USER_FILE="$ENV_FILE"; USER_SOURCE=".env"
fi

FO_URL="${URL}/"
BO_URL="${URL}/admin-dev/"
JOB_KEYS=()
while IFS= read -r key; do
  if [[ "$key" =~ ^PRESTAFLOW_[A-Za-z0-9_.]*$ ]] && ! is_integration_var "$key"; then
    JOB_KEYS+=("$key")
  fi
done < <(compgen -e | LC_ALL=C sort)

{
  echo "# Generated by $GENERATOR for the Flashlight run."
  echo "# Later assignments win. The original file is restored after the run."
  echo ""
  echo "# Flashlight default accounts (back office and demo customer)"
  echo "PRESTAFLOW_BO_EMAIL=$(dotenv_value 'admin@prestashop.com')"
  echo "PRESTAFLOW_BO_PASSWD=$(dotenv_value 'prestashop')"
  echo "PRESTAFLOW_FO_EMAIL=$(dotenv_value 'pub@prestashop.com')"
  echo "PRESTAFLOW_FO_PASSWD=$(dotenv_value '123456789')"
  echo ""
  if [ -n "$USER_FILE" ]; then
    echo "# --- user dotenv file ($USER_SOURCE) ---"
    # Verbatim (phpdotenv reads its own syntax), without trailing blank lines,
    # and always ending with a newline.
    awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i] }' "$USER_FILE"
    echo "# --- end of user dotenv file ---"
    echo ""
  fi
  echo "# Flashlight instance"
  echo "PRESTAFLOW_FO_URL=$(dotenv_value "$FO_URL")"
  echo "PRESTAFLOW_BO_URL=$(dotenv_value "$BO_URL")"
  if [ -n "$PS_VERSION" ]; then
    echo "PRESTAFLOW_PS_VERSION=$(dotenv_value "$PS_VERSION")"
  fi
  if [ "${#JOB_KEYS[@]}" -gt 0 ]; then
    echo ""
    echo "# Job variables (PRESTAFLOW_*)"
    for key in "${JOB_KEYS[@]}"; do
      echo "${key}=$(dotenv_value "${!key}")"
    done
  fi
} > "$ENV_LOCAL"

{
  printf '%s\n' PRESTAFLOW_BO_EMAIL PRESTAFLOW_BO_PASSWD PRESTAFLOW_FO_EMAIL PRESTAFLOW_FO_PASSWD
  printf '%s\n' PRESTAFLOW_FO_URL PRESTAFLOW_BO_URL
  if [ -n "$PS_VERSION" ]; then printf '%s\n' PRESTAFLOW_PS_VERSION; fi
  if [ "${#JOB_KEYS[@]}" -gt 0 ]; then printf '%s\n' "${JOB_KEYS[@]}"; fi
} | LC_ALL=C sort -u > "$KEYS_FILE"

if [ "$USER_SOURCE" = ".env.local" ]; then
  echo "flashlight: existing .env.local merged into the generated one; it will be restored after the run"
fi
SUMMARY="Flashlight values"
[ -n "$USER_SOURCE" ] && SUMMARY="$SUMMARY + $USER_SOURCE"
[ "${#JOB_KEYS[@]}" -gt 0 ] && SUMMARY="$SUMMARY + ${#JOB_KEYS[@]} PRESTAFLOW_* job variable(s)"
echo "flashlight: wrote $ENV_LOCAL ($SUMMARY)"

# Keep them around for downstream steps (prestaflow.env, $BASH_ENV) too.
echo "export PRESTAFLOW_FO_URL=${FO_URL}" >> "$BASH_ENV"
{
  echo "PRESTAFLOW_FO_URL=${FO_URL}"
  echo "PRESTAFLOW_BO_URL=${BO_URL}"
  if [ -n "$PS_VERSION" ]; then echo "PRESTAFLOW_PS_VERSION=${PS_VERSION}"; fi
  echo "PRESTAFLOW_FLASHLIGHT_TAG=${IMAGE_TAG}"
} >> "$WORKSPACE/prestaflow.env"

echo "flashlight: ready at ${FO_URL} (image ${IMAGE_TAG}, PS ${PS_VERSION:-unknown})"
