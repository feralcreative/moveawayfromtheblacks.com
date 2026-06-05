#!/usr/bin/env bash
# moveawayfromtheblacks.com — Production deploy wrapper.
# Pass --dry-run to preview, --force to bypass git-clean / on-main gates.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ENV="prod"
exec "$SCRIPT_DIR/deploy.sh" "$@"
