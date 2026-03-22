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

# ── Load config ──────────────────────────────────────────────
CONFIG_FILE="${1:-${SCRIPT_DIR}/config.conf}"
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
  apply_argocd_apps
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
  header "Port-Forward ArgoCD"
  echo -e "  Forwarding ${BOLD}localhost:8080 -> argocd-server:443${NC}"
  echo -e "  Open: ${BOLD}http://localhost:8080${NC}"
  echo -e "  Press Ctrl+C to stop."
  echo ""
  kubectl port-forward -n "$ARGOCD_NAMESPACE" svc/argocd-server 8080:443
}

# ── Menu ─────────────────────────────────────────────────────
show_menu() {
  header "kind-apps-cluster  —  Local K8s + ArgoCD"
  echo ""
  echo -e "  ${BOLD}1)${NC} Full deploy (cluster + gateway + argocd + apps)"
  echo -e "  ${BOLD}2)${NC} Create / verify kind cluster only"
  echo -e "  ${BOLD}3)${NC} Install Gateway API (cloud-provider-kind)"
  echo -e "  ${BOLD}4)${NC} Install ArgoCD"
  echo -e "  ${BOLD}5)${NC} Apply ArgoCD applications from ${ARGOCD_APPS_DIR}"
  echo -e "  ${BOLD}6)${NC} Show status of all components"
  echo -e "  ${BOLD}7)${NC} Get ArgoCD admin password"
  echo -e "  ${BOLD}8)${NC} Port-forward ArgoCD (http://localhost:8080) — fallback method"
  echo -e "  ${BOLD}9)${NC} Delete cluster"
  echo ""
  echo -e "  ${BOLD}0)${NC} Exit"
  echo ""
}

main() {
  if [[ "${1:-}" == "--non-interactive" || "${1:-}" == "-y" ]]; then
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
      8) action_port_forward_argocd ;;
      9) action_delete_cluster ;;
      0) echo "Bye."; exit 0 ;;
      *) log_warn "Invalid option." ;;
    esac
    echo ""
  done
}

main "$@"
