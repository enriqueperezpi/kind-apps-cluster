#!/usr/bin/env bash
# cert-manager.sh — cert-manager deployment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_cert_manager_installed() {
  kubectl get namespace "$CERT_MANAGER_NAMESPACE" &>/dev/null && \
    kubectl get deployment cert-manager -n "$CERT_MANAGER_NAMESPACE" &>/dev/null
}

install_cert_manager() {
  if _cert_manager_installed; then
    log_warn "cert-manager is already installed — helm upgrade to reconcile."
  else
    log_info "Creating namespace '${CERT_MANAGER_NAMESPACE}'…"
    kubectl create namespace "$CERT_MANAGER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  fi

  log_info "Installing cert-manager (${CERT_MANAGER_VERSION}) via Helm…"
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update jetstack

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERT_MANAGER_NAMESPACE" \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set prometheus.enabled=false \
    --wait --timeout 5m

  log_info "Waiting for cert-manager pods…"
  wait_for_deployment "$CERT_MANAGER_NAMESPACE" "cert-manager" 300
  wait_for_deployment "$CERT_MANAGER_NAMESPACE" "cert-manager-webhook" 300
  wait_for_deployment "$CERT_MANAGER_NAMESPACE" "cert-manager-cainjector" 300

  log_success "cert-manager installed."
}

create_cluster_issuer() {
  log_info "Creating ClusterIssuer 'selfsigned' (for local dev)…"

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

  log_success "ClusterIssuer 'selfsigned-issuer' created."
}

install_cert_manager_full() {
  install_cert_manager
  create_cluster_issuer
}

cert_manager_status() {
  echo ""
  if _cert_manager_installed; then
    log_success "cert-manager is installed in '${CERT_MANAGER_NAMESPACE}'."
    kubectl get pods -n "$CERT_MANAGER_NAMESPACE" --no-headers 2>/dev/null || true

    if kubectl get clusterissuer selfsigned-issuer &>/dev/null; then
      log_success "ClusterIssuer 'selfsigned-issuer' exists."
    else
      log_warn "ClusterIssuer 'selfsigned-issuer' does NOT exist."
    fi
  else
    log_warn "cert-manager is NOT installed."
  fi
}
