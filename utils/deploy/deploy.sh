#!/usr/bin/env bash
# moveawayfromtheblacks.com — Deploy via SFTP, then purge Cloudflare cache.
# Don't run directly — use prod.sh, which sets DEPLOY_ENV.
#
# Transport note: this NAS is reached over SFTP (same as the VSCode SFTP
# extension). We deliberately do NOT use rsync — macOS ships Apple's openrsync,
# which fails against the Synology rsync with "io_read / unexpected end of file".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/deploy-utils.sh"

DOMAIN="moveawayfromtheblacks.com"

# Allowlist of files to publish (relative to project root). An allowlist — not
# an exclude list — guarantees secrets (.env) and tooling (utils/, .git) can
# never reach the public web root.
DEPLOY_FILES=( index.html .htaccess )

# Parse flags
DRY_RUN=""; FORCE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --force|-f)   FORCE=1 ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--dry-run] [--force]

Deploys ${DOMAIN} to the NAS via SFTP, then purges the Cloudflare cache.

  --dry-run, -n   Show what would be uploaded without transferring anything.
  --force,   -f   Bypass prod safety gates (does NOT bypass confirmation).

Called via:
  utils/deploy/prod.sh    # deploys to production
EOF
      exit 0 ;;
    *) err "Unknown flag: $arg"; exit 1 ;;
  esac
done

[ -n "${DEPLOY_ENV:-}" ] || { err "DEPLOY_ENV not set — run prod.sh"; exit 1; }
[ "$DEPLOY_ENV" = "prod" ] || { err "Invalid DEPLOY_ENV: $DEPLOY_ENV"; exit 1; }

require_cmd sftp "OpenSSH SFTP client is required."
require_cmd ssh  "OpenSSH client is required."
require_cmd jq   "Install with 'brew install jq'."
require_cmd git  "Git is required."
require_cmd curl "curl is required for the Cloudflare purge."

cd "$PROJECT_ROOT"
DEPLOY_START=$(date +%s)

# Load .env (Cloudflare creds, optional SSH_KEY_PATH override)
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a; source "$PROJECT_ROOT/.env"; set +a
fi

# Zone ID default (overridable via .env)
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-696f90c8f24f2613a084c2454a5c2dde}"

# Read target from .vscode/sftp.json (flat profile — no .profiles block)
SFTP_JSON="$PROJECT_ROOT/.vscode/sftp.json"
[ -f "$SFTP_JSON" ] || { err "Missing $SFTP_JSON — can't resolve target."; exit 1; }

HOST=$(jq -r '.host' "$SFTP_JSON")
SSH_USER=$(jq -r '.username' "$SFTP_JSON")
SSH_PORT=$(jq -r '.port // 22' "$SFTP_JSON")
REMOTE_PATH=$(jq -r '.remotePath' "$SFTP_JSON")

[ "$HOST" != "null" ] || { err "Could not read .host from $SFTP_JSON"; exit 1; }
[ "$REMOTE_PATH" != "null" ] || { err "Could not read .remotePath from $SFTP_JSON"; exit 1; }

TARGET_URL="https://${DOMAIN}"
ENV_LABEL="PRODUCTION"; ENV_COLOR="$RED"

echo ""
echo -e "${CYAN}═══ ${DOMAIN} — ${ENV_COLOR}${ENV_LABEL}${NC}${CYAN} deploy ═══${NC}"
echo -e "  Target : ${BOLD}${SSH_USER}@${HOST}:${REMOTE_PATH}${NC}"
echo -e "  Files  : ${BOLD}${DEPLOY_FILES[*]}${NC}"
[ -n "$DRY_RUN" ] && warn "DRY RUN — nothing will be uploaded, no cache purged"

# Verify every allowlisted file exists locally before we start
for f in "${DEPLOY_FILES[@]}"; do
  [ -f "$PROJECT_ROOT/$f" ] || { err "Missing local file: $f"; exit 1; }
done

# Production safety gates
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

if [ -z "$FORCE" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    err "Working tree is dirty. Commit/stash, or pass --force."; exit 1
  fi
  if [ "$GIT_BRANCH" != "main" ]; then
    err "Not on 'main' (current: $GIT_BRANCH). Switch or pass --force."; exit 1
  fi
fi

if [ -z "$DRY_RUN" ]; then
  echo ""
  echo -e "${RED}${BOLD}⚠  You are about to deploy to PRODUCTION${NC}"
  echo -e "   URL    : ${BOLD}${TARGET_URL}${NC}"
  echo -e "   Commit : ${BOLD}${GIT_SHA}${NC} on ${BOLD}${GIT_BRANCH}${NC}"
  [ -n "$FORCE" ] && echo -e "   Mode   : ${YELLOW}--force (gates bypassed)${NC}"
  read -r -p "Type 'yes' to continue: " CONFIRM
  [ "$CONFIRM" = "yes" ] || { err "Aborted."; exit 1; }
fi

# SFTP connection options (lean on ssh-agent; honor optional SSH_KEY_PATH)
SFTP_OPTS=(-P "$SSH_PORT" -o ConnectTimeout=15)
[ -n "${SSH_KEY_PATH:-}" ] && [ -f "$SSH_KEY_PATH" ] && SFTP_OPTS+=(-i "$SSH_KEY_PATH")
SFTP_TARGET="${SSH_USER}@${HOST}"

# Build the SFTP batch: create the remote path (each component, tolerant of
# "already exists"), then upload each file. '-' prefix ignores per-command
# errors; 'put' is left un-prefixed so a failed upload fails the deploy.
BATCH_FILE=$(mktemp -t sftp-batch.XXXXXX)
cleanup() { rm -f "$BATCH_FILE"; }
trap cleanup EXIT

{
  rel=""
  IFS='/' read -ra PARTS <<< "${REMOTE_PATH#/}"
  for comp in "${PARTS[@]}"; do
    rel="${rel}/${comp}"
    echo "-mkdir ${rel}"
  done
  echo "cd ${REMOTE_PATH}"
  for f in "${DEPLOY_FILES[@]}"; do
    echo "put \"${PROJECT_ROOT}/${f}\" \"${f}\""
  done
  echo "ls -la"
  echo "bye"
} > "$BATCH_FILE"

info "Uploading ${#DEPLOY_FILES[@]} file(s) over SFTP..."
UPLOAD_START=$(date +%s)

if [ -n "$DRY_RUN" ]; then
  warn "DRY RUN — would run the following SFTP batch:"
  sed 's/^/    /' "$BATCH_FILE"
  UPLOAD_TIME=0
else
  if sftp "${SFTP_OPTS[@]}" -b "$BATCH_FILE" "$SFTP_TARGET"; then
    UPLOAD_TIME=$(($(date +%s) - UPLOAD_START))
    ok "Files uploaded in $(format_time $UPLOAD_TIME)"
  else
    err "SFTP upload failed. Check the host/path in .vscode/sftp.json and that"
    err "your SSH key is loaded (ssh-add -l)."
    exit 1
  fi
fi

# Cloudflare cache purge (non-fatal)
purge_cloudflare_cache() {
  if [ -n "$DRY_RUN" ]; then
    warn "DRY RUN — skipping Cloudflare cache purge"; return 0
  fi
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ZONE_ID:-}" ]; then
    warn "Cloudflare credentials not set in .env — skipping cache purge"; return 0
  fi
  info "Purging Cloudflare cache (zone ${CLOUDFLARE_ZONE_ID})..."
  local response
  response=$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"purge_everything":true}')
  if echo "$response" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    ok "Cloudflare cache purged"
  else
    warn "Cloudflare cache purge failed (non-fatal)"
  fi
}
purge_cloudflare_cache

TOTAL_TIME=$(($(date +%s) - DEPLOY_START))

# Summary
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}${ENV_COLOR}${ENV_LABEL} DEPLOY SUMMARY${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  Target       : ${BOLD}${TARGET_URL}${NC}"
echo -e "  Remote path  : ${DIM}${REMOTE_PATH}${NC}"
echo -e "  Git          : ${BOLD}${GIT_SHA}${NC} (${GIT_BRANCH})"
echo -e "  Upload time  : $(format_time $UPLOAD_TIME)"
echo -e "  Total time   : ${GREEN}$(format_time $TOTAL_TIME)${NC}"
echo -e "  Timestamp    : $(date '+%Y-%m-%d %H:%M:%S')"
[ -n "$DRY_RUN" ] && echo -e "  ${YELLOW}Mode         : DRY RUN (nothing uploaded)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

if [ -n "$DRY_RUN" ]; then
  warn "Dry-run complete. Re-run without --dry-run to push for real."
else
  ok "${ENV_LABEL} deploy complete → ${TARGET_URL}"
fi
