#!/usr/bin/env bash
# argocd.sh — ArgoCD deployment and management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_argocd_installed() {
  kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null && \
    kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" &>/dev/null
}

install_argocd() {
  if _argocd_installed; then
    log_warn "ArgoCD is already installed in '${ARGOCD_NAMESPACE}'. Applying manifest to ensure consistency…"
  else
    log_info "Creating namespace '${ARGOCD_NAMESPACE}'…"
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  fi

  local manifest="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  log_info "Applying ArgoCD manifest (${ARGOCD_VERSION})…"
  kubectl apply -n "$ARGOCD_NAMESPACE" -f "$manifest"

  log_info "Waiting for ArgoCD server to be ready…"
  wait_for_deployment "$ARGOCD_NAMESPACE" "argocd-server" 600

  log_info "Waiting for remaining ArgoCD pods…"
  wait_for_pods_ready "$ARGOCD_NAMESPACE" "" 300

  log_success "ArgoCD deployed."
}

patch_argocd_server() {
  if ! _argocd_installed; then
    log_error "ArgoCD is not installed."
    return 1
  fi

  log_info "Configuring ArgoCD server for insecure mode (HTTP behind Gateway)…"

  # The official way: set server.insecure in argocd-cmd-params-cm
  kubectl apply -n "$ARGOCD_NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
data:
  server.insecure: "true"
EOF

  # Restart server to pick up the config change
  log_info "Restarting ArgoCD server to apply changes…"
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server
  wait_for_deployment "$ARGOCD_NAMESPACE" "argocd-server" 300

  log_success "ArgoCD server configured for insecure mode."
}

apply_argocd_apps() {
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  if [[ ! -d "$apps_dir" ]]; then
    log_warn "Apps directory '${apps_dir}' does not exist — skipping."
    return 0
  fi

  local count
  count=$(find "$apps_dir" -maxdepth 1 -name '*.yaml' -o -name '*.yml' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -eq 0 ]]; then
    log_warn "No YAML files found in '${apps_dir}'."
    return 0
  fi

  log_info "Applying ArgoCD Application/ApplicationSet configs from '${apps_dir}'…"
  for f in "$apps_dir"/*.yaml "$apps_dir"/*.yml; do
    [[ -f "$f" ]] || continue
    log_info "  -> $(basename "$f")"
    kubectl apply -f "$f"
  done
  log_success "ArgoCD apps applied."
}

argocd_admin_password() {
  if ! _argocd_installed; then
    log_error "ArgoCD is not installed."
    return 1
  fi

  local pw
  pw=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [[ -n "$pw" ]]; then
    echo -e "${GREEN}ArgoCD admin password: ${BOLD}${pw}${NC}"
  else
    log_warn "Initial admin secret not found (may have been changed)."
  fi
}

argocd_status() {
  if _argocd_installed; then
    log_success "ArgoCD is installed in namespace '${ARGOCD_NAMESPACE}'."
    echo ""
    kubectl get pods -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null || true
  else
    log_warn "ArgoCD is not installed."
  fi
}

argocd_gateway_info() {
  header "ArgoCD Access via Gateway API"

  echo -e "  ${BOLD}Direct Access (Recommended):${NC}"
  echo -e "    1. Add to /etc/hosts:"
  echo -e "       ${CYAN}echo '127.0.0.1 argocd.local' | sudo tee -a /etc/hosts${NC}"
  echo -e "    2. Visit: ${BOLD}http://argocd.local${NC}"
  echo ""

  echo -e "  ${BOLD}Or use port-forward (if direct access doesn't work):${NC}"
  echo -e "    ${CYAN}kubectl port-forward -n ${ARGOCD_NAMESPACE} svc/argocd-server 8080:443${NC}"
  echo -e "    URL: ${BOLD}http://localhost:8080${NC}"
  echo ""

  echo -e "  ${BOLD}Login Credentials:${NC}"
  echo -e "    User: ${BOLD}admin${NC}"
  argocd_admin_password
  separator
}
