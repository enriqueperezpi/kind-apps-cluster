#!/usr/bin/env bash
# gateway-api.sh — Envoy reverse proxy + NodePort ingress for local k8s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_envoy_running() {
  kubectl get deployment envoy-ingress -n "${ARGOCD_NAMESPACE}" &>/dev/null
}

install_envoy_reverse_proxy() {
  log_info "Installing Envoy reverse proxy (NodePort ingress)…"

  # Ensure namespace exists
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Create Envoy ConfigMap with routing configuration
  # This routes all requests to argocd-server on port 80
  # Additional services can be added by modifying this ConfigMap
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-config
  namespace: ${ARGOCD_NAMESPACE}
data:
  envoy.yaml: |
    static_resources:
      listeners:
      - name: listener_0
        address:
          socket_address:
            address: 0.0.0.0
            port_value: 8080
        filter_chains:
        - filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
              stat_prefix: ingress_http
              codec_type: AUTO
              route_config:
                name: local_route
                virtual_hosts:
                - name: argocd_vhost
                  domains: ["*"]
                  routes:
                  - match:
                      prefix: "/"
                    route:
                      cluster: argocd-cluster
                      timeout: 30s
              http_filters:
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
      clusters:
      - name: argocd-cluster
        connect_timeout: 5s
        type: LOGICAL_DNS
        dns_lookup_family: V4_ONLY
        load_assignment:
          cluster_name: argocd-cluster
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local
                    port_value: 80
        health_checks:
        - timeout: 5s
          interval: 10s
          unhealthy_threshold: 2
          healthy_threshold: 2
          http_health_check:
            path: "/"
            expected_statuses:
            - start: 200
              end: 399
    admin:
      access_log_path: /tmp/admin_access.log
      address:
        socket_address:
          address: 127.0.0.1
          port_value: 9901
EOF

  # Deploy Envoy as Deployment
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: envoy-ingress
  namespace: ${ARGOCD_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: envoy-ingress
  template:
    metadata:
      labels:
        app: envoy-ingress
    spec:
      containers:
      - name: envoy
        image: envoyproxy/envoy:v1.27-latest
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        volumeMounts:
        - name: envoy-config
          mountPath: /etc/envoy
        args:
        - /usr/local/bin/envoy
        - "-c"
        - "/etc/envoy/envoy.yaml"
        - "-l"
        - "info"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
      volumes:
      - name: envoy-config
        configMap:
          name: envoy-config
---
apiVersion: v1
kind: Service
metadata:
  name: envoy-ingress
  namespace: ${ARGOCD_NAMESPACE}
spec:
  type: NodePort
  selector:
    app: envoy-ingress
  ports:
  - name: http
    port: 80
    targetPort: 8080
    nodePort: ${HTTP_PORT}
    protocol: TCP
EOF

  log_success "Envoy reverse proxy deployed as NodePort service."
  log_info "Envoy is listening on all nodes at port ${HTTP_PORT} (NodePort)"
}

create_argocd_gateway() {
  # No longer needed with Envoy approach, but keep function for backward compatibility
  log_info "Envoy reverse proxy is already routing to ArgoCD."
}

install_gateway_api() {
  install_envoy_reverse_proxy
  create_argocd_gateway
}

gateway_api_status() {
  echo ""
  if _envoy_running; then
    log_success "Envoy reverse proxy is running."
    
    # Show envoy pod status
    local pod_status
    pod_status=$(kubectl get pods -n "${ARGOCD_NAMESPACE}" -l app=envoy-ingress -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
    echo "  Pod status: ${pod_status}"
    
    # Show service status
    local nodeport
    nodeport=$(kubectl get svc envoy-ingress -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "pending")
    echo "  NodePort: ${nodeport}"
  else
    log_warn "Envoy reverse proxy is NOT running."
    log_info "Deploy it with: kubectl apply -f lib/gateway-api.sh"
  fi

  if kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_success "ArgoCD service (argocd-server) exists."
    local svc_port
    svc_port=$(kubectl get svc argocd-server -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "unknown")
    echo "  Service port: ${svc_port}"
  else
    log_warn "ArgoCD service (argocd-server) does NOT exist."
  fi
}
