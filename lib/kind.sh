#!/usr/bin/env bash
# kind.sh — kind cluster lifecycle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

# Check if the Docker container for the control-plane is actually running
_cluster_healthy() {
  if ! _cluster_exists; then
    return 1
  fi
  local node="${CLUSTER_NAME}-control-plane"
  docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null | grep -q "true"
}

# Detect if we're on macOS
_is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

# Check if cluster creation actually succeeded
_verify_cluster_created() {
  if ! _cluster_exists; then
    log_error "Cluster '${CLUSTER_NAME}' was NOT created successfully."
    return 1
  fi
  
  if ! _cluster_healthy; then
    log_error "Cluster '${CLUSTER_NAME}' exists but container is not running."
    log_info "Docker may have failed. Check Docker Desktop logs."
    return 1
  fi
  
  return 0
}

generate_kind_config() {
  # Check if using Cilium CNI
  local cni_plugin=""
  if [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    cni_plugin="none"
  fi

  cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: $([[ "$cni_plugin" == "none" ]] && echo "true" || echo "false")
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: ${HTTP_PORT}
    protocol: TCP
    listenAddress: "0.0.0.0"
  - containerPort: 443
    hostPort: ${HTTPS_PORT}
    protocol: TCP
    listenAddress: "0.0.0.0"
EOF

  # Only add BPF mounts on Linux (not macOS)
  if ! _is_macos && [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    cat <<EOF
  extraMounts:
  - hostPath: /sys/kernel/bpf
    containerPath: /sys/kernel/bpf
    readOnly: true
  - hostPath: /run/cilium
    containerPath: /run/cilium
EOF
  fi

  for i in $(seq 1 "${WORKER_NODES}"); do
    cat <<EOF
- role: worker
EOF
    # Only add BPF mounts on Linux (not macOS)
    if ! _is_macos && [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
      cat <<EOF
  extraMounts:
  - hostPath: /sys/kernel/bpf
    containerPath: /sys/kernel/bpf
    readOnly: true
  - hostPath: /run/cilium
    containerPath: /run/cilium
EOF
    fi
  done
}

create_cluster() {
  if _cluster_healthy; then
    log_warn "Cluster '${CLUSTER_NAME}' already exists and is healthy — skipping creation."
    _ensure_kind_context
    return 0
  fi

  # Cluster exists but container is dead — clean up first
  if _cluster_exists; then
    log_warn "Cluster '${CLUSTER_NAME}' exists but is not healthy — deleting and recreating…"
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  fi

  log_info "Creating kind cluster '${CLUSTER_NAME}' (k8s ${K8S_VERSION})…"

  # Check Docker is running
  if ! docker info &>/dev/null; then
    log_error "Docker is not running or not accessible."
    log_info "Please start Docker Desktop and try again."
    return 1
  fi

  local config_file
  config_file=$(mktemp)
  generate_kind_config > "$config_file"

  # Capture the exit code
  local create_result=0
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --image "kindest/node:${K8S_VERSION}" \
    --config "$config_file" \
    --wait 120s 2>&1 || create_result=$?

  rm -f "$config_file"

  # Check if creation actually succeeded
  if [[ $create_result -ne 0 ]]; then
    log_error "Cluster creation failed with exit code: ${create_result}"
    log_info "Common issues:"
    log_info "  - Ports 80/443 already in use"
    log_info "  - Docker Desktop resources insufficient"
    log_info "  - /sys/kernel/bpf mount failed (try without Cilium)"
    return 1
  fi

  # Double-check cluster health
  sleep 3
  if ! _verify_cluster_created; then
    return 1
  fi

  log_success "Cluster '${CLUSTER_NAME}' created and verified."
  
  # Ensure kubectl uses the right context
  _ensure_kind_context
}

_ensure_kind_context() {
  # Verify we're using the kind cluster context
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
  
  if [[ "$current_context" != "kind-${CLUSTER_NAME}" ]]; then
    log_info "Switching kubectl context to kind-${CLUSTER_NAME}…"
    kubectl config use-context "kind-${CLUSTER_NAME}"
  fi
}

delete_cluster() {
  if ! _cluster_exists; then
    log_warn "Cluster '${CLUSTER_NAME}' does not exist — nothing to delete."
    return 0
  fi

  if confirm "Delete cluster '${CLUSTER_NAME}'?"; then
    kind delete cluster --name "$CLUSTER_NAME"
    log_success "Cluster '${CLUSTER_NAME}' deleted."
  fi
}

ensure_kubeconfig() {
  if ! _cluster_exists; then
    log_error "Cluster '${CLUSTER_NAME}' does not exist. Create it first."
    return 1
  fi

  if ! _cluster_healthy; then
    log_error "Cluster '${CLUSTER_NAME}' exists but its container is not running."
    log_error "Delete it first (option 9) and recreate."
    return 1
  fi

  _ensure_kind_context

  # Verify kubectl can reach the cluster
  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to cluster '${CLUSTER_NAME}'."
    log_info "Try: kubectl config use-context kind-${CLUSTER_NAME}"
    return 1
  fi

  log_success "kubectl configured for cluster '${CLUSTER_NAME}'."
}

cluster_status() {
  if ! _cluster_exists; then
    log_warn "Cluster '${CLUSTER_NAME}' does not exist."
    return 0
  fi

  echo "  Cluster: ${CLUSTER_NAME}"
  
  if _cluster_healthy; then
    echo "  Status: healthy (running)"
    
    # Show node info
    echo ""
    kubectl get nodes -o wide
    
    # Show cluster info
    echo ""
    kubectl cluster-info
  else
    echo "  Status: unhealthy (container not running)"
    log_info "Delete and recreate the cluster (option 9, then option 1)."
  fi
}
