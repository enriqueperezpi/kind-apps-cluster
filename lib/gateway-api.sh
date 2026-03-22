#!/usr/bin/env bash
# gateway-api.sh — Cilium as Gateway API controller for local k8s
# Uses Cilium CNI with Gateway API support for kind
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

CILIUM_VERSION="${CILIUM_VERSION:-1.17.2}"
CILIUM_NAMESPACE="cilium"
GATEWAY_API_NAMESPACE="gateway-api"

_install_kind_config() {
  log_info "Cilium requires special kind cluster configuration…"
  
  # Check if cluster exists with Cilium config
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_warn "Cluster '${CLUSTER_NAME}' exists. To use Cilium, you must delete and recreate it."
    log_info "Run: kind delete cluster --name ${CLUSTER_NAME}"
    log_info "Then re-run this setup."
    return 1
  fi
  
  return 0
}

install_gateway_api() {
  # Install Gateway API CRDs first
  install_gateway_api_crds
  
  # Install Cilium with Gateway API support
  install_cilium
  
  # Create Gateway API infrastructure namespace
  kubectl create namespace "${GATEWAY_API_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  
  # Create GatewayClass
  create_gateway_class
  
  # Create Gateway
  create_gateway
  
  # Create ArgoCD HTTPRoute
  create_argocd_httproute
  
  # Create HTTPRoutes for apps
  create_app_httproutes
}

install_gateway_api_crds() {
  if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    log_info "Gateway API CRDs already installed."
    return 0
  fi

  log_info "Installing Gateway API CRDs (${GATEWAY_API_VERSION:-v1.2.0})…"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION:-v1.2.0}/standard-install.yaml"
  log_success "Gateway API CRDs installed."
}

install_cilium() {
  if kubectl get pods -n "${CILIUM_NAMESPACE}" -l k8s-app=cilium 2>/dev/null | grep -q Running; then
    log_success "Cilium is already running."
    return 0
  fi

  log_info "Installing Cilium ${CILIUM_VERSION} with Gateway API support…"

  # Create namespace
  kubectl create namespace "${CILIUM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  # Add Helm repo
  helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
  helm repo update

  # Install Cilium with Gateway API
  helm install cilium cilium/cilium \
    --namespace "${CILIUM_NAMESPACE}" \
    --version "${CILIUM_VERSION}" \
    --set gatewayAPI.enabled=true \
    --set gatewayAPI.enableGatewayAPIAdmissionWebhook=true \
    --set gatewayAPI.enableGatewayAPIStatus=true \
    --set ipam.mode=kubernetes \
    --wait --timeout 15m

  # Wait for Cilium to be ready
  log_info "Waiting for Cilium to be ready…"
  kubectl wait --namespace "${CILIUM_NAMESPACE}" \
    --for=condition=ready \
    pod -l k8s-app=cilium \
    --timeout=10m

  log_success "Cilium installed successfully."
}

create_gateway_class() {
  log_info "Creating Cilium GatewayClass…"

  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
EOF

  log_success "GatewayClass 'cilium' created."
}

create_gateway() {
  log_info "Creating Gateway for HTTP traffic…"

  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gateway
  namespace: ${ARGOCD_NAMESPACE}
  annotations:
    cilium.io/gateway: "true"
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF

  log_success "Gateway 'cilium-gateway' created in namespace ${ARGOCD_NAMESPACE}."
}

create_argocd_httproute() {
  log_info "Creating HTTPRoute for ArgoCD (argocd.local)…"

  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: ${ARGOCD_NAMESPACE}
spec:
  parentRefs:
  - name: cilium-gateway
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

  log_success "HTTPRoute for ArgoCD created."
}

create_app_httproutes() {
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  
  if [[ ! -d "$apps_dir" ]]; then
    log_warn "Apps directory '${apps_dir}' not found."
    return 0
  fi

  # Find all httproute files
  local count
  count=$(find "$apps_dir" -name 'httproute.yaml' -o -name 'httproute.yml' 2>/dev/null | wc -l | tr -d ' ')
  
  if [[ "$count" -eq 0 ]]; then
    log_info "No HTTPRoute files found in '${apps_dir}'."
    return 0
  fi

  log_info "Creating ${count} HTTPRoute(s) from '${apps_dir}'…"
  
  while IFS= read -r -d '' httproute_file; do
    local app_name
    app_name=$(basename "$(dirname "$httproute_file")")
    log_info "  -> ${app_name}/httproute.yaml"
    kubectl apply -f "$httproute_file"
  done < <(find "$apps_dir" -name 'httproute.yaml' -o -name 'httproute.yml' -print0)
  
  log_success "Created ${count} HTTPRoute(s)."
}

gateway_api_status() {
  echo ""
  
  # Cilium status
  if kubectl get pods -n "${CILIUM_NAMESPACE}" -l k8s-app=cilium 2>/dev/null | grep -q Running; then
    log_success "Cilium is running."
    kubectl get pods -n "${CILIUM_NAMESPACE}" -l k8s-app=cilium --no-headers | head -3
  else
    log_warn "Cilium is NOT running."
  fi

  # GatewayClass
  if kubectl get gatewayclass cilium &>/dev/null; then
    log_success "GatewayClass 'cilium' exists."
  else
    log_warn "GatewayClass 'cilium' not found."
  fi

  # Gateway
  if kubectl get gateway cilium-gateway -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_success "Gateway 'cilium-gateway' exists."
    kubectl get gateway cilium-gateway -n "${ARGOCD_NAMESPACE}"
  else
    log_warn "Gateway 'cilium-gateway' not found."
  fi

  # HTTPRoutes
  local count
  count=$(kubectl get httproute --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    echo ""
    log_info "HTTPRoutes:"
    kubectl get httproute --all-namespaces
  fi
}
