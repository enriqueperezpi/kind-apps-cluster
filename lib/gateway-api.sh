#!/usr/bin/env bash
# gateway-api.sh — Gateway API CRDs + cloud-provider-kind as controller
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_gateway_api_crds_installed() {
  kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null
}

_cloud_provider_kind_running() {
  docker ps --filter name=cloud-provider-kind 2>/dev/null | grep -q cloud-provider-kind
}

install_gateway_api_crds() {
  if _gateway_api_crds_installed; then
    log_warn "Gateway API CRDs already present — applying to ensure latest version."
  fi

  log_info "Installing Gateway API CRDs (${GATEWAY_API_VERSION})…"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  log_success "Gateway API CRDs installed."
}

install_cloud_provider_kind() {
  if _cloud_provider_kind_running; then
    log_warn "cloud-provider-kind is already running."
    return 0
  fi

  log_info "Installing cloud-provider-kind (Gateway API controller + LoadBalancer provider)…"
  
  # Get the latest version
  local version
  version=$(basename "$(curl -s -L -o /dev/null -w '%{url_effective}' https://github.com/kubernetes-sigs/cloud-provider-kind/releases/latest 2>/dev/null)" || echo "v0.1.0")
  log_info "Using cloud-provider-kind version: ${version}"

  # Stop any existing container
  docker stop cloud-provider-kind 2>/dev/null || true
  docker rm cloud-provider-kind 2>/dev/null || true

  # Run cloud-provider-kind as Docker container
  docker run -d \
    --name cloud-provider-kind \
    --rm \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${version}"

  # Wait for it to start
  log_info "Waiting for cloud-provider-kind to start…"
  sleep 3

  if _cloud_provider_kind_running; then
    log_success "cloud-provider-kind started successfully."
  else
    log_error "Failed to start cloud-provider-kind. Check Docker logs:"
    docker logs cloud-provider-kind || true
    return 1
  fi
}

create_argocd_gateway() {
  log_info "Creating Gateway and HTTPRoute for ArgoCD…"

  # Ensure namespace exists (ArgoCD may not be installed yet)
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Create single Gateway for all services
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: ${ARGOCD_NAMESPACE}
spec:
  gatewayClassName: cloud-provider-kind
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF

  # Create HTTPRoute for ArgoCD
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-route
  namespace: ${ARGOCD_NAMESPACE}
spec:
  parentRefs:
  - name: main-gateway
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
      port: 80
EOF

  log_success "Gateway (main-gateway) and HTTPRoute (argocd-route) created."
  log_info "Additional services can be added as new HTTPRoutes pointing to the same Gateway."
}

install_gateway_api() {
  install_gateway_api_crds
  install_cloud_provider_kind
  create_argocd_gateway
}

gateway_api_status() {
  echo ""
  if _gateway_api_crds_installed; then
    log_success "Gateway API CRDs are installed."
  else
    log_warn "Gateway API CRDs are NOT installed."
  fi

  if _cloud_provider_kind_running; then
    log_success "cloud-provider-kind is running."
    
    # Show cloud-provider-kind logs (last few lines)
    local logs
    logs=$(docker logs cloud-provider-kind 2>/dev/null | tail -3 || echo "")
    if [[ -n "$logs" ]]; then
      echo "  Recent logs:"
      echo "$logs" | sed 's/^/    /'
    fi
  else
    log_warn "cloud-provider-kind is NOT running."
    log_info "Start it with: docker run -d --name cloud-provider-kind --rm --network host -v /var/run/docker.sock:/var/run/docker.sock registry.k8s.io/cloud-provider-kind/cloud-controller-manager:latest"
  fi

  if kubectl get gateway main-gateway -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_success "Gateway (main-gateway) exists."
    
    # Show gateway status
    local gw_addresses
    gw_addresses=$(kubectl get gateway main-gateway -n "${ARGOCD_NAMESPACE}" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")
    echo "  Listening address: ${gw_addresses}"
  else
    log_warn "Gateway (main-gateway) does NOT exist."
  fi

  if kubectl get httproute argocd-route -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_success "HTTPRoute (argocd-route) exists."
  else
    log_warn "HTTPRoute (argocd-route) does NOT exist."
  fi
}
