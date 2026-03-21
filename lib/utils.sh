#!/usr/bin/env bash
# utils.sh — common helpers
set -euo pipefail

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

separator() {
  echo -e "${CYAN}────────────────────────────────────────────${NC}"
}

wait_for_pods_ready() {
  local namespace="${1}"
  local label="${2:-}"
  local timeout="${3:-300}"

  log_info "Waiting for pods in '${namespace}' (label: ${label:-all}) to be ready (timeout ${timeout}s)…"

  local selector=""
  [[ -n "$label" ]] && selector="-l ${label}"

  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local pods
    pods=$(kubectl get pods -n "$namespace" $selector --no-headers 2>/dev/null || true)

    # No pods yet — not ready
    if [[ -z "$pods" ]]; then
      sleep 5
      continue
    fi

    local not_ready
    not_ready=$(echo "$pods" | grep -cvE "Running|Completed" || true)
    if [[ "$not_ready" -eq 0 ]]; then
      log_success "All pods in '${namespace}' are ready."
      return 0
    fi
    sleep 5
  done

  log_error "Timed out waiting for pods in '${namespace}'."
  kubectl get pods -n "$namespace" $selector --no-headers 2>/dev/null || true
  return 1
}

wait_for_deployment() {
  local namespace="${1}"
  local deployment="${2}"
  local timeout="${3:-300}"

  log_info "Waiting for deployment '${deployment}' in '${namespace}' (timeout ${timeout}s)…"
  if kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
    log_success "Deployment '${deployment}' is ready."
    return 0
  fi
  log_error "Timed out waiting for deployment '${deployment}'."
  return 1
}

confirm() {
  local prompt="${1:-Continue?}"
  read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

header() {
  echo ""
  separator
  echo -e "${BOLD}${CYAN}  $*${NC}"
  separator
}
