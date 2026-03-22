#!/usr/bin/env bash
# gateway-api.sh — Gateway API controller setup for kind
# Supports Cilium (full Gateway API) or kind networking (basic routing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

# Configuration from config.conf
CILIUM_VERSION="${CILIUM_VERSION:-1.17.2}"
CILIUM_NAMESPACE="cilium"
ARGOCD_LOCAL_PORT="${ARGOCD_LOCAL_PORT:-8080}"
PORT_FORWARD_PID_FILE="${SCRIPT_DIR}/.argocd-port-forward.pid"

# ── kubectl context verification ──────────────────────────────────────────────
_verify_kubectl_for_gateway() {
  # Ensure we're using the kind cluster context
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null || echo "")
  
  if [[ "$current_context" != "kind-${CLUSTER_NAME}" ]]; then
    log_error "kubectl is using context '${current_context}', but we need kind-${CLUSTER_NAME}."
    log_info "Switching context…"
    kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || {
      log_error "Failed to switch kubectl context. Is the cluster running?"
      return 1
    }
  fi
  
  # Verify cluster is reachable
  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to cluster '${CLUSTER_NAME}'."
    log_info "Make sure the cluster is running: kind get clusters"
    return 1
  fi
  
  return 0
}

# ── Install Gateway API CRDs ───────────────────────────────────────────────
install_gateway_api_crds() {
  if ! _verify_kubectl_for_gateway; then
    return 1
  fi
  
  if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    log_info "Gateway API CRDs already installed."
    return 0
  fi

  log_info "Installing Gateway API CRDs (${GATEWAY_API_VERSION:-v1.2.0})…"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION:-v1.2.0}/standard-install.yaml"
  log_success "Gateway API CRDs installed."
}

# ── Install Cilium (if configured) ────────────────────────────────────────
install_cilium_if_needed() {
  if [[ "${CNI_PLUGIN:-kind}" != "cilium" ]]; then
    log_info "Using kind networking (CNI_PLUGIN=${CNI_PLUGIN}). Skipping Cilium."
    log_info "For Gateway API support, set CNI_PLUGIN=\"cilium\" in config.conf."
    return 0
  fi
  
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

# ── Create Gateway resources ─────────────────────────────────────────────────
create_gateway_class() {
  if [[ "${CNI_PLUGIN:-kind}" != "cilium" ]]; then
    return 0
  fi
  
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
  if [[ "${CNI_PLUGIN:-kind}" != "cilium" ]]; then
    log_info "Gateway resources require Cilium CNI (CNI_PLUGIN=\"cilium\")."
    return 0
  fi
  
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
  if [[ "${CNI_PLUGIN:-kind}" != "cilium" ]]; then
    log_info "HTTPRoutes require Cilium CNI. ArgoCD accessible via port-forward."
    log_info "Run: kubectl port-forward -n argocd svc/argocd-server 8080:80"
    return 0
  fi
  
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
  
  if [[ "${CNI_PLUGIN:-kind}" != "cilium" ]]; then
    return 0
  fi
  
  if [[ ! -d "$apps_dir" ]]; then
    return 0
  fi

  # Find all httproute files
  local count
  count=$(find "$apps_dir" -name 'httproute.yaml' -o -name 'httproute.yml' 2>/dev/null | wc -l | tr -d ' ')
  
  if [[ "$count" -eq 0 ]]; then
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

# ── ArgoCD Local Access (port-forward fallback) ─────────────────────────────────
start_argocd_port_forward() {
  if [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    return 0
  fi

  if [[ -f "$PORT_FORWARD_PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$PORT_FORWARD_PID_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log_info "ArgoCD port-forward already running (PID: ${old_pid})"
      return 0
    else
      rm -f "$PORT_FORWARD_PID_FILE"
    fi
  fi

  if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    log_warn "ArgoCD not installed. Install ArgoCD first."
    return 1
  fi

  log_info "Starting ArgoCD port-forward on localhost:${ARGOCD_LOCAL_PORT}…"
  
  kubectl port-forward -n "$ARGOCD_NAMESPACE" svc/argocd-server "${ARGOCD_LOCAL_PORT}:80" &>/dev/null &
  local new_pid=$!
  echo "$new_pid" > "$PORT_FORWARD_PID_FILE"
  
  sleep 2
  
  if kill -0 "$new_pid" 2>/dev/null; then
    log_success "ArgoCD accessible at http://localhost:${ARGOCD_LOCAL_PORT}"
    return 0
  else
    log_error "Failed to start port-forward"
    rm -f "$PORT_FORWARD_PID_FILE"
    return 1
  fi
}

stop_argocd_port_forward() {
  if [[ -f "$PORT_FORWARD_PID_FILE" ]]; then
    local pid
    pid=$(cat "$PORT_FORWARD_PID_FILE" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_info "Stopping ArgoCD port-forward (PID: ${pid})…"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PORT_FORWARD_PID_FILE"
  fi
}

setup_argocd_local_access() {
  if [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    log_info "Using Gateway API for ArgoCD access (Cilium mode)"
    return 0
  fi
  
  log_info "Setting up ArgoCD localhost access (kind networking mode)…"
  start_argocd_port_forward
}

argocd_gateway_info() {
  if [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    echo ""
    echo "  ArgoCD Access (Gateway API):"
    echo "  ─────────────────────────────────"
    echo "  URL: http://argocd.local"
    echo "  Note: Add '127.0.0.1 argocd.local' to /etc/hosts"
    echo "  Or use port-forward: kubectl port-forward -n ${ARGOCD_NAMESPACE} svc/argocd-server 8080:80"
  else
    echo ""
    echo "  ArgoCD Access (Port-Forward):"
    echo "  ─────────────────────────────────"
    if [[ -f "$PORT_FORWARD_PID_FILE" ]]; then
      local pid
      pid=$(cat "$PORT_FORWARD_PID_FILE" 2>/dev/null)
      if kill -0 "$pid" 2>/dev/null; then
        echo "  URL: http://localhost:${ARGOCD_LOCAL_PORT}"
        echo "  Port-forward PID: ${pid}"
      else
        echo "  Port-forward not running"
        echo "  Run: ./setup.sh --argocd-local"
      fi
    else
      echo "  URL: http://localhost:${ARGOCD_LOCAL_PORT}"
      echo "  Port-forward not running"
      echo "  Run: ./setup.sh --argocd-local"
    fi
  fi
}

# ── Main install function ────────────────────────────────────────────────────
install_gateway_api() {
  log_info "Installing Gateway API infrastructure…"
  
  # Verify kubectl context first
  if ! _verify_kubectl_for_gateway; then
    log_error "Cannot proceed without valid kubectl context."
    return 1
  fi
  
  # Install Gateway API CRDs
  install_gateway_api_crds
  
  # Install Cilium if configured
  install_cilium_if_needed
  
  # Create Gateway resources
  create_gateway_class
  create_gateway
  create_argocd_httproute
  create_app_httproutes
  
  log_success "Gateway API setup complete."
}

# ── Status check ────────────────────────────────────────────────────────────
gateway_api_status() {
  echo ""
  
  # Check kubectl context
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
  echo "  kubectl context: ${current_context}"
  
  # Cilium status
  if [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    if kubectl get pods -n "${CILIUM_NAMESPACE}" -l k8s-app=cilium 2>/dev/null | grep -q Running; then
      log_success "Cilium is running."
      kubectl get pods -n "${CILIUM_NAMESPACE}" -l k8s-app=cilium --no-headers | head -2
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
    else
      log_warn "Gateway 'cilium-gateway' not found."
    fi
  else
    log_info "Using kind networking (CNI_PLUGIN=${CNI_PLUGIN:-kind})."
    log_info "Set CNI_PLUGIN=\"cilium\" in config.conf for Gateway API support."
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
