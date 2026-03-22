#!/usr/bin/env bash
# gateway-api.sh — Nginx reverse proxy with hostNetwork for local k8s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_ingress_proxy_running() {
  kubectl get daemonset ingress-proxy -n "${ARGOCD_NAMESPACE}" &>/dev/null
}

install_ingress_proxy() {
  log_info "Installing Nginx reverse proxy (hostNetwork DaemonSet)…"

  # Get ArgoCD service ClusterIP
  local argocd_ip
  argocd_ip=$(kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "argocd-server")
  
  # Get kube-dns IP for resolver
  local dns_ip
  dns_ip=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.96.0.10")

  # Ensure namespace exists
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Create Nginx ConfigMap
  # Routes all requests from host port 80 to ArgoCD service
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-proxy-config
  namespace: ${ARGOCD_NAMESPACE}
data:
  default.conf: |
    server {
        listen 80;
        server_name _;
        
        location / {
            proxy_pass http://${argocd_ip}:80;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
EOF

  # Deploy Nginx as DaemonSet with hostNetwork
  # Runs on ALL nodes (control-plane + workers) with tolerations
  # Binds directly to host port 80
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ingress-proxy
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    app: ingress-proxy
spec:
  selector:
    matchLabels:
      app: ingress-proxy
  template:
    metadata:
      labels:
        app: ingress-proxy
    spec:
      hostNetwork: true
      # Tolerate control-plane NoSchedule taint
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
          hostPort: 80
          name: http
          protocol: TCP
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
          readOnly: true
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
      volumes:
      - name: nginx-config
        configMap:
          name: ingress-proxy-config
EOF

  # Wait for pods to be ready
  log_info "Waiting for ingress proxy to start on all nodes…"
  sleep 5

  # Verify pods are running
  local pod_count
  pod_count=$(kubectl get pods -n "${ARGOCD_NAMESPACE}" -l app=ingress-proxy --no-headers 2>/dev/null | wc -l)
  if [[ "$pod_count" -ge 1 ]]; then
    log_success "Nginx reverse proxy deployed (${pod_count} pod(s) with hostNetwork)."
    log_info "Listening on host port 80 → routes to ArgoCD"
  else
    log_warn "Ingress proxy pods not ready yet. Check status with: kubectl get pods -n ${ARGOCD_NAMESPACE} -l app=ingress-proxy"
  fi
}

create_argocd_gateway() {
  log_info "Nginx reverse proxy is routing to ArgoCD."
  log_info "Access ArgoCD at: http://localhost:80"
  log_info "Add to /etc/hosts: echo '127.0.0.1 argocd.local' | sudo tee -a /etc/hosts"
}

install_gateway_api() {
  install_ingress_proxy
  create_argocd_gateway
}

gateway_api_status() {
  echo ""
  if _ingress_proxy_running; then
    log_success "Nginx reverse proxy (DaemonSet) is running."
    
    # Show pod status per node
    kubectl get pods -n "${ARGOCD_NAMESPACE}" -l app=ingress-proxy -o wide
    
    # Show which port it's bound to
    echo "  Host binding: port 80 (hostNetwork)"
  else
    log_warn "Nginx reverse proxy is NOT running."
  fi

  if kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_success "ArgoCD service (argocd-server) exists."
    local argocd_port
    argocd_port=$(kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "unknown")
    echo "  ArgoCD port: ${argocd_port}"
  else
    log_warn "ArgoCD service (argocd-server) does NOT exist."
  fi
}
