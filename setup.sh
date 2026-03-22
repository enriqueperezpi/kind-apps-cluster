#!/usr/bin/env bash
# setup.sh — kind-apps-cluster: interactive local Kubernetes + ArgoCD setup
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run a labelled step; failures are reported but don't abort the full deploy.
run_step() {
  local label="$1"; shift
  log_info "▶ ${label}"
  if "$@"; then
    log_success "✔ ${label}"
  else
    log_error "✘ ${label} failed (exit $?) — continuing."
    return 0
  fi
}

# ── Parse command-line arguments ────────────────────────────
NON_INTERACTIVE=false
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
TARGET_APP=""
APP_MODE=""  # "enable", "disable", or ""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      NON_INTERACTIVE=true
      shift
      ;;
    -f|--config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --enable)
      TARGET_APP="$2"
      APP_MODE="enable"
      shift 2
      ;;
    --disable)
      TARGET_APP="$2"
      APP_MODE="disable"
      shift 2
      ;;
    --list-apps)
      TARGET_APP="__list__"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  -y, --yes              Non-interactive full deploy"
      echo "  -f, --config <file>    Use custom config file"
      echo "  --enable <app>         Enable an application"
      echo "  --disable <app>        Disable an application"
      echo "  --list-apps            List all applications"
      echo "  -h, --help             Show this help"
      exit 0
      ;;
    *)
      echo -e "\033[1;31m[ERROR]\033[0m  Unknown option: $1"
      echo "Usage: $0 [-y|--yes] [-f|--config <file>] [--enable <app>] [--disable <app>]"
      exit 1
      ;;
  esac
done

# ── Load config ──────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=config.conf
  source "$CONFIG_FILE"
  echo -e "\033[0;34m[INFO]\033[0m  Loaded config from ${CONFIG_FILE}"
else
  echo -e "\033[1;33m[WARN]\033[0m  Config file '${CONFIG_FILE}' not found — using defaults."
fi

# ── Load library modules ────────────────────────────────────
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/tools.sh"
source "${SCRIPT_DIR}/lib/kind.sh"

# ── Check kubectl context ───────────────────────────────────
_verify_kubectl_context() {
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null || echo "")
  
  # If no cluster exists, that's ok - it will be created
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    return 0
  fi
  
  # Cluster exists, ensure we're using the right context
  if [[ "$current_context" != "kind-${CLUSTER_NAME}" ]]; then
    echo -e "\033[1;33m[WARN]\033[0m  kubectl is using context '${current_context}', but cluster '${CLUSTER_NAME}' exists."
    echo -e "       Switching to kind-${CLUSTER_NAME}…"
    kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || {
      echo -e "\033[1;31m[ERROR]\033[0m  Failed to switch kubectl context."
      return 1
    }
  fi
}

# Verify context early
_verify_kubectl_context || true
source "${SCRIPT_DIR}/lib/argocd.sh"
source "${SCRIPT_DIR}/lib/gateway-api.sh"

# ── Helpers ──────────────────────────────────────────────────
need_cluster() {
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log_error "Cluster '${CLUSTER_NAME}' does not exist. Create it first (option 1)."
    return 1
  fi
  ensure_kubeconfig
}

# ── Actions ──────────────────────────────────────────────────
action_full_deploy() {
  header "Full Deploy"

  run_step "Check & install tools"       check_and_install_tools
  run_step "Create kind cluster"         create_cluster
  run_step "Set kubeconfig"              ensure_kubeconfig

  run_step "Install Gateway API (cloud-provider-kind)" install_gateway_api
  run_step "Install ArgoCD"               install_argocd
  run_step "Patch ArgoCD server"          patch_argocd_server
  run_step "Create ArgoCD Gateway"        create_argocd_gateway
  run_step "Apply ArgoCD apps"            apply_argocd_apps
  run_step "Setup ArgoCD local access"    setup_argocd_local_access

  header "Deploy Summary"
  cluster_status
  echo ""
  argocd_status
  echo ""
  gateway_api_status
  echo ""
  argocd_gateway_info
}

action_cluster_only() {
  header "Create / Verify Cluster"
  check_and_install_tools
  create_cluster
  ensure_kubeconfig
  cluster_status
}

action_install_gateway_api() {
  need_cluster || return
  header "Install Gateway API (cloud-provider-kind)"
  install_gateway_api
  gateway_api_status
}

action_install_argocd() {
  need_cluster || return
  header "Install ArgoCD"
  install_argocd
  patch_argocd_server
  create_argocd_gateway
  argocd_gateway_info
}

action_apply_apps() {
  need_cluster || return
  header "Apply ArgoCD Applications"
  list_argocd_apps
  apply_argocd_apps
}

action_list_apps() {
  header "ArgoCD Applications"
  list_argocd_apps
}

action_enable_app() {
  header "Enable Application"
  local app_name="${1:-}"
  if [[ -z "$app_name" ]]; then
    list_argocd_apps
    echo "Usage: ./setup.sh --enable <app-name>"
    return 0
  fi
  enable_argocd_app "$app_name"
}

action_disable_app() {
  header "Disable Application"
  local app_name="${1:-}"
  if [[ -z "$app_name" ]]; then
    list_argocd_apps
    echo "Usage: ./setup.sh --disable <app-name>"
    return 0
  fi
  disable_argocd_app "$app_name"
}

action_status() {
  need_cluster || return
  header "Cluster Status"
  cluster_status
  echo ""
  argocd_status
  echo ""
  gateway_api_status
}

action_get_argocd_password() {
  need_cluster || return
  argocd_admin_password
}

action_delete_cluster() {
  header "Delete Cluster"
  delete_cluster
}

action_port_forward_argocd() {
  need_cluster || return
  setup_argocd_local_access
  argocd_gateway_info
}

action_argocd_local_access() {
  need_cluster || return
  header "ArgoCD Local Access"
  setup_argocd_local_access
  argocd_gateway_info
}

# ── Menu ─────────────────────────────────────────────────────
show_menu() {
  header "kind-apps-cluster  —  Local K8s + ArgoCD + Gateway API"
  echo ""
  echo -e "  ${BOLD}1)${NC} Full deploy (cluster + ${CNI_PLUGIN:-kind} + argocd + apps)"
  echo -e "  ${BOLD}2)${NC} Create / verify kind cluster only"
  echo -e "  ${BOLD}3)${NC} Install Gateway API + Cilium controller"
  echo -e "  ${BOLD}4)${NC} Install ArgoCD"
  echo -e "  ${BOLD}5)${NC} Apply ArgoCD applications from ${ARGOCD_APPS_DIR}"
  echo -e "  ${BOLD}6)${NC} Show status of all components"
  echo -e "  ${BOLD}7)${NC} Get ArgoCD admin password"
  echo -e "  ${BOLD}8)${NC} ArgoCD local access (port-forward)"
  echo -e "  ${BOLD}9)${NC} Delete cluster"
  echo ""
  echo -e "  ${DIM}CLI flags:${NC}"
  echo -e "  ${DIM}  --list-apps          List available apps${NC}"
  echo -e "  ${DIM}  --enable <app>       Enable an app before applying${NC}"
  echo -e "  ${DIM}  --disable <app>      Disable an app (comments out YAML)${NC}"
  echo -e "  ${DIM}  -y                   Non-interactive full deploy${NC}"
  echo ""
  echo -e "  ${BOLD}0)${NC} Exit"
  echo ""
}

main() {
  # Handle --list-apps first
  if [[ "$TARGET_APP" == "__list__" ]]; then
    source "${SCRIPT_DIR}/lib/argocd.sh"
    action_list_apps
    return
  fi

  # Handle --enable and --disable
  if [[ -n "$APP_MODE" ]]; then
    source "${SCRIPT_DIR}/lib/argocd.sh"
    case "$APP_MODE" in
      enable)
        action_enable_app "$TARGET_APP"
        ;;
      disable)
        action_disable_app "$TARGET_APP"
        ;;
    esac
    return
  fi

  # Non-interactive full deploy
  if [[ "$NON_INTERACTIVE" == true ]]; then
    action_full_deploy
    return
  fi

  while true; do
    show_menu
    read -rp "$(echo -e "${BOLD}Select an option: ${NC}")" choice
    case "$choice" in
      1) action_full_deploy ;;
      2) action_cluster_only ;;
      3) action_install_gateway_api ;;
      4) action_install_argocd ;;
      5) action_apply_apps ;;
      6) action_status ;;
      7) action_get_argocd_password ;;
      8) action_argocd_local_access ;;
      9) action_delete_cluster ;;
      0) echo "Bye."; exit 0 ;;
      *) log_warn "Invalid option." ;;
    esac
    echo ""
  done
}

main
