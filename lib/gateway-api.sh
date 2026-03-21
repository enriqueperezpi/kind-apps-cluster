#!/usr/bin/env bash
# gateway-api.sh — Gateway API CRDs + Cilium as gateway controller + MetalLB for kind
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

METALLAB_NAMESPACE="metallb-system"

_gateway_api_crds_installed() {
  kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null
}

_cilium_installed() {
  kubectl -n kube-system get deployment cilium &>/dev/null || \
    kubectl -n kube-system get daemonset cilium &>/dev/null
}

_metallb_installed() {
  kubectl get namespace "$METALLAB_NAMESPACE" &>/dev/null && \
    kubectl get deployment controller -n "$METALLAB_NAMESPACE" &>/dev/null
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

# Discover the Docker network subnet for MetalLB
_get_metallb_ip_range() {
  local node_ip
  node_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER_NAME}-control-plane" 2>/dev/null)

  if [[ -z "$node_ip" ]]; then
    log_error "Could not determine control-plane container IP."
    return 1
  fi

  local base
  base=$(echo "$node_ip" | awk -F. '{print $1"."$2"."$3}')
  echo "${base}.200-${base}.215"
}

install_metallb() {
  if _metallb_installed; then
    log_warn "MetalLB is already installed — skipping."
  else
    log_info "Installing MetalLB…"
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml"

    log_info "Waiting for MetalLB pods…"
    wait_for_pods_ready "$METALLAB_NAMESPACE" "" 300
  fi

  local ip_range
  ip_range=$(_get_metallb_ip_range)

  log_info "Configuring MetalLB IP pool: ${ip_range}"
  kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: ${METALLAB_NAMESPACE}
spec:
  addresses:
  - ${ip_range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: ${METALLAB_NAMESPACE}
spec:
  ipAddressPools:
  - kind-pool
EOF

  log_success "MetalLB configured."
}

# Add a host route so the LoadBalancer IP is reachable from the host.
# kind runs inside Docker — the MetalLB IP lives on the Docker bridge
# which the host can't reach without an explicit route.
_add_host_route() {
  local lb_ip="$1"

  # Try to get the Docker bridge gateway for the kind network
  local gateway
  gateway=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)

  if [[ -z "$gateway" ]]; then
    log_warn "Could not discover Docker network gateway."
    _print_fallback_instructions "$lb_ip"
    return 1
  fi

  # Quick check — can we already reach it?
  if ping -c 1 -W 2 "$lb_ip" &>/dev/null; then
    log_success "LoadBalancer IP ${lb_ip} is already reachable from host."
    return 0
  fi

  log_info "Adding host route: ${lb_ip} via ${gateway}…"

  local os
  os=$(uname -s)
  case "$os" in
    Darwin)
      # macOS — route may already exist (exit 71 = File exists)
      if sudo route -n add -host "$lb_ip" "$gateway" 2>/dev/null; then
        log_success "Route added."
      elif sudo route -n get "$lb_ip" &>/dev/null; then
        log_warn "Route to ${lb_ip} already exists — skipping."
      else
        log_warn "Could not add route automatically."
        _print_fallback_instructions "$lb_ip"
        return 1
      fi
      ;;
    Linux)
      if sudo ip route add "${lb_ip}/32" via "$gateway" 2>/dev/null; then
        log_success "Route added."
      elif ip route get "$lb_ip" &>/dev/null; then
        log_warn "Route to ${lb_ip} already exists — skipping."
      else
        log_warn "Could not add route automatically."
        _print_fallback_instructions "$lb_ip"
        return 1
      fi
      ;;
    *)
      log_warn "Unsupported platform '${os}'."
      _print_fallback_instructions "$lb_ip"
      return 1
      ;;
  esac
}

_print_fallback_instructions() {
  local lb_ip="$1"
  echo ""
  echo -e "  ${YELLOW}Alternative access methods:${NC}"
  echo ""
  echo "  Option A — Add route manually (requires sudo):"
  echo "    macOS:  sudo route -n add -host ${lb_ip} \$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')"
  echo "    Linux:  sudo ip route add ${lb_ip}/32 via \$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')"
  echo ""
  echo "  Option B — kubectl port-forward:"
  echo "    kubectl port-forward -n ${ARGOCD_NAMESPACE} svc/cilium-gateway-argocd-gateway 8080:80"
  echo "    Then open http://localhost:8080"
  echo ""
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
  - "argocd.localtest.me"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: argocd-server
      port: 443
EOF

  # Wait for the Gateway to get an address from MetalLB
  log_info "Waiting for Gateway address to be assigned…"
  local addr=""
  local end=$((SECONDS + 120))
  while (( SECONDS < end )); do
    addr=$(kubectl get gateway argocd-gateway -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -z "$addr" ]]; then
    log_warn "Gateway address not assigned yet — it may take a moment."
    log_success "ArgoCD Gateway and HTTPRoute created."
    return 0
  fi

  log_success "Gateway address: ${addr}"

  # Make the IP reachable from the host
  _add_host_route "$addr" || true

  log_success "ArgoCD Gateway and HTTPRoute created."
}

install_gateway_api() {
  install_gateway_api_crds
  install_cilium
  install_metallb
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

  if _metallb_installed; then
    log_success "MetalLB is installed."
  else
    log_warn "MetalLB is NOT installed."
  fi

  if kubectl get gateway argocd-gateway -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    local addr
    addr=$(kubectl get gateway argocd-gateway -n "${ARGOCD_NAMESPACE}" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then
      log_success "ArgoCD Gateway exists (address: ${addr})."
      # Verify reachability
      if ping -c 1 -W 2 "$addr" &>/dev/null; then
        log_success "Gateway address ${addr} is reachable from host."
      else
        log_warn "Gateway address ${addr} is NOT reachable from host — run _add_host_route or use port-forward."
      fi
    else
      log_warn "ArgoCD Gateway exists but has NO address assigned."
    fi
  else
    log_warn "ArgoCD Gateway does NOT exist."
  fi
}
