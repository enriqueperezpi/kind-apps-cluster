#!/usr/bin/env bash
# gateway-api.sh — Gateway API CRDs + Cilium as gateway controller
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_gateway_api_crds_installed() {
  kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null
}

_cilium_installed() {
  kubectl -n kube-system get deployment cilium &>/dev/null || \
    kubectl -n kube-system get daemonset cilium &>/dev/null
}

install_gateway_api_crds() {
  if _gateway_api_crds_installed; then
    log_warn "Gateway API CRDs already present — applying to ensure latest version."
  fi

  log_info "Installing Gateway API CRDs (${GATEWAY_API_VERSION})…"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  log_success "Gateway API CRDs installed."
}

install_cilium() {
  if _cilium_installed; then
    log_warn "Cilium is already installed — helm upgrade to reconcile."
  fi

  log_info "Installing Cilium via Helm (gateway-api enabled)…"
  helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
  helm repo update cilium

  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${CLUSTER_NAME}-control-plane" \
    --set k8sServicePort=6443 \
    --set gatewayAPI.enabled=true \
    --set hubble.enabled=false \
    --wait --timeout 5m

  log_info "Waiting for Cilium pods…"
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s 2>/dev/null || \
    kubectl -n kube-system rollout status deployment/cilium --timeout=300s 2>/dev/null || true

  log_success "Cilium installed with Gateway API support."
}

create_argocd_gateway() {
  log_info "Creating Gateway and HTTPRoute for ArgoCD…"

  # Ensure namespace exists (ArgoCD may not be installed yet)
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: argocd-gateway
  namespace: ${ARGOCD_NAMESPACE}
spec:
  gatewayClassName: ${GATEWAY_CLASS_NAME}
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-route
  namespace: ${ARGOCD_NAMESPACE}
spec:
  parentRefs:
  - name: argocd-gateway
    namespace: ${ARGOCD_NAMESPACE}
  hostnames:
  - "argocd.local"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: argocd-server
      port: 443
EOF

  log_success "ArgoCD Gateway and HTTPRoute created."
}

install_gateway_api() {
  install_gateway_api_crds
  install_cilium
  create_argocd_gateway
}

gateway_api_status() {
  echo ""
  if _gateway_api_crds_installed; then
    log_success "Gateway API CRDs are installed."
  else
    log_warn "Gateway API CRDs are NOT installed."
  fi

  if _cilium_installed; then
    log_success "Cilium is installed."
  else
    log_warn "Cilium is NOT installed."
  fi

  if kubectl get gateway argocd-gateway -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_success "ArgoCD Gateway exists."
  else
    log_warn "ArgoCD Gateway does NOT exist."
  fi
}
