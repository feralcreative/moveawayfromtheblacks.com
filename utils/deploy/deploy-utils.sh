#!/usr/bin/env bash
# Shared helpers for deploy.sh — not meant to be run directly.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info() { echo -e "${BLUE}▶${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1" >&2; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }

format_time() { local s=$1; if [ "$s" -lt 60 ]; then echo "${s}s"; else echo "$((s/60))m $((s%60))s"; fi; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found. ${2:-}"; exit 1; }; }
