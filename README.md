# kind-apps-cluster

Local Kubernetes cluster with ArgoCD, Gateway API (Cilium + MetalLB), and cert-manager — all managed by an idempotent bash script.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  kind cluster                                                    │
│                                                                  │
│  ┌─────────────┐  ┌──────────┐  ┌──────────────┐  ┌──────────┐  │
│  │   Cilium    │  │ MetalLB  │  │ cert-manager │  │  ArgoCD  │  │
│  │ Gateway API │  │  (L2)    │  │ (selfsigned) │  │  Server  │  │
│  └──────┬──────┘  └────┬─────┘  └──────────────┘  └─────┬────┘  │
│         │               │                                │       │
│         │  LoadBalancer IP (e.g. 172.18.0.200)           │       │
│         │               │                                │       │
│         └─── Gateway ───┼── HTTPRoute ───────────────────┘       │
│                                                                  │
└──────────────────────────┬───────────────────────────────────────┘
                           │
        host route / port-forward
                           │
                    ┌──────┴──────┐
                    │   Browser   │
                    │  localhost  │
                    └─────────────┘
```

### Traffic flow

```
Browser
  │
  ├─ Option A: Gateway IP + host route
  │    http://172.18.0.200 ──► Docker bridge ──► MetalLB ──► Cilium ──► ArgoCD
  │
  └─ Option B: kubectl port-forward (recommended on macOS)
       http://localhost:8080 ──► port-forward ──► ArgoCD Service ──► ArgoCD Pod
```

## Prerequisites

| Tool     | Auto-installed? |
|----------|----------------|
| `kind`   | yes            |
| `kubectl`| yes            |
| `helm`   | yes            |
| Docker   | **no** — must be running |

> **Docker** (or any OCI-compatible runtime) is required by `kind` and must be installed and running before you start.

## Quick Start

```bash
# 1. Clone the repo
git clone <repo-url> && cd kind-apps-cluster

# 2. Review / edit config (optional)
vim config.conf

# 3. Run full deploy (interactive menu)
./setup.sh

# ... or non-interactive full deploy
./setup.sh --non-interactive
```

After the full deploy completes the script will print the Gateway IP, ArgoCD admin password, and access instructions.

## Usage

### Interactive Menu

Run `./setup.sh` to get the menu:

```
  1)  Full deploy (cluster + gateway + cert-mgr + argocd + apps)
  2)  Create / verify kind cluster only
  3)  Install Gateway API + Cilium
  4)  Install cert-manager
  5)  Install ArgoCD
  6)  Apply ArgoCD applications from ./argocd-apps
  7)  Show status of all components
  8)  Get ArgoCD admin password
  9)  Port-forward ArgoCD (http://localhost:8080)
  10) Delete cluster
  0)  Exit
```

Every option is **idempotent** — you can run any of them multiple times safely.

### Non-Interactive Mode

```bash
./setup.sh --non-interactive   # or ./setup.sh -y
```

This performs a full deploy (option 1) without prompting.

### Custom Config File

```bash
./setup.sh /path/to/my-config.conf
```

## Accessing ArgoCD

The script deploys a Gateway API `Gateway` with a MetalLB-assigned IP (e.g. `172.18.0.200`). Since this IP lives on the Docker bridge network, you have two options to reach it:

### Option A — Port-forward (recommended, no sudo)

```bash
./setup.sh   # option 9
```

Opens `http://localhost:8080` → ArgoCD UI. Press Ctrl+C to stop.

### Option B — Host route (direct access to Gateway IP)

The script attempts this automatically during deploy. If it fails or you want to set it up manually:

```bash
# 1. Get the Docker bridge gateway
docker_gateway=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')
echo "Docker gateway: $docker_gateway"

# 2. Get the MetalLB-assigned Gateway IP (or use 172.18.0.200 as default)
lb_ip=$(kubectl get svc cilium-gateway-argocd-gateway -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "172.18.0.200")
echo "LoadBalancer IP: $lb_ip"

# 3. Delete any incorrect existing route
# macOS:
sudo route -n delete -host "$lb_ip" 2>/dev/null || true
# Linux:
sudo ip route delete "$lb_ip/32" 2>/dev/null || true

# 4. Add the correct route
# macOS:
sudo route -n add -host "$lb_ip" "$docker_gateway"
# Linux:
sudo ip route add "$lb_ip/32" via "$docker_gateway"

# 5. Test it
ping "$lb_ip"
curl http://"$lb_ip"
```

Then open `http://$lb_ip` in your browser.

### Credentials

- **User:** `admin`
- **Password:** shown after deploy (or run `./setup.sh` → option 8)

## Configuration (`config.conf`)

All parameters live in `config.conf` and can be overridden with environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `kind-apps-cluster` | kind cluster name |
| `K8S_VERSION` | `v1.32.3` | Kubernetes version (kind node image tag) |
| `WORKER_NODES` | `1` | Number of worker nodes |
| `ARGOCD_NAMESPACE` | `argocd` | Namespace for ArgoCD |
| `ARGOCD_VERSION` | `stable` | ArgoCD manifest version |
| `ARGOCD_APPS_DIR` | `./argocd-apps` | Directory with Application/ApplicationSet YAMLs |
| `GATEWAY_API_VERSION` | `v1.2.0` | Gateway API CRD version |
| `GATEWAY_CLASS_NAME` | `cilium` | GatewayClass to use |
| `CERT_MANAGER_VERSION` | `v1.16.2` | cert-manager Helm chart version |
| `CERT_MANAGER_NAMESPACE` | `cert-manager` | Namespace for cert-manager |
| `AUTO_INSTALL_TOOLS` | `true` | Auto-install missing CLI tools |
| `HTTP_PORT` | `80` | Host port mapped to HTTP |
| `HTTPS_PORT` | `443` | Host port mapped to HTTPS |

## Components

| Component | Purpose | How it works |
|-----------|---------|--------------|
| **kind** | Local K8s cluster | Docker-based, ports 80/443 mapped to control-plane |
| **Cilium** | CNI + Gateway controller | Replaces kube-proxy and nginx-ingress; implements Gateway API |
| **MetalLB** | LoadBalancer IPs in kind | L2 advertisement from Docker bridge subnet |
| **Gateway API** | Ingress standard | CRDs (`Gateway`, `HTTPRoute`) — Cilium is the controller |
| **cert-manager** | Certificate management | Installed with selfsigned `ClusterIssuer` for local dev |
| **ArgoCD** | GitOps CD | Deploys apps from `argocd-apps/` directory |

## Deploying Applications with ArgoCD

### Add Applications

Drop `Application` or `ApplicationSet` YAML files into the `argocd-apps/` directory. They will be applied automatically during a full deploy or manually via menu option 6.

```yaml
# argocd-apps/my-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/repo.git
    targetRevision: main
    path: k8s/
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Then apply:

```bash
./setup.sh   # option 6 — Apply ArgoCD applications
```

## Project Structure

```
kind-apps-cluster/
├── setup.sh              # Main entry point (menu + non-interactive)
├── config.conf           # All configurable parameters
├── lib/
│   ├── utils.sh          # Logging, wait helpers
│   ├── tools.sh          # Tool detection & installation
│   ├── kind.sh           # kind cluster lifecycle (health checks)
│   ├── argocd.sh         # ArgoCD install, insecure config, Gateway info
│   ├── gateway-api.sh    # Gateway API CRDs + Cilium + MetalLB + HTTPRoute
│   └── cert-manager.sh   # cert-manager + ClusterIssuer
└── argocd-apps/
    ├── README.md
    └── example-guestbook.yaml
```

## Idempotency

The script is designed to be re-run safely at any time:

- **Cluster**: detects unhealthy containers and recreates automatically.
- **Helm charts** (Cilium, cert-manager): `helm upgrade --install` — reconciles to desired state.
- **MetalLB**: IP pool and L2Advertisement are applied (overwrite on re-run).
- **ArgoCD**: config is set via `argocd-cmd-params-cm` ConfigMap + rollout restart.
- **ArgoCD apps**: `kubectl apply` is naturally idempotent.

## Troubleshooting

**Docker not running**
```
ERROR: failed to create cluster: could not find a container runtime
```
→ Start Docker Desktop or your container runtime.

**Ports 80/443 in use**
→ Edit `HTTP_PORT` / `HTTPS_PORT` in `config.conf`.

**MetalLB Gateway has no IP**
```bash
kubectl get pods -n metallb-system           # check MetalLB pods
kubectl get gateway -n argocd                # check Gateway status
kubectl get svc -n argocd | grep gateway     # check LoadBalancer service
```

**Gateway IP not reachable from host**

This happens because MetalLB assigns IPs on Docker's internal bridge (172.18.0.0/16), which requires an explicit host route.

```bash
# Check if the route exists and points to the correct gateway
route -n get 172.18.0.200        # macOS
ip route get 172.18.0.200        # Linux

# Get the correct Docker bridge gateway
docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}'
# Example output: 172.18.0.1

# If route doesn't exist OR points to wrong gateway, fix it:
# macOS
sudo route -n delete -host 172.18.0.200        # delete any incorrect route
sudo route -n add -host 172.18.0.200 172.18.0.1

# Linux
sudo ip route delete 172.18.0.200/32 || true
sudo ip route add 172.18.0.200/32 via 172.18.0.1

# Verify it works
ping 172.18.0.200
curl http://172.18.0.200
```

**Or use port-forward instead (no sudo required)**
```bash
./setup.sh   # option 9
# Access via http://localhost:8080
```

**ArgoCD not loading (connection refused)**
```bash
kubectl get pods -n argocd                          # check pods
kubectl get configmap argocd-cmd-params-cm -n argocd -o yaml   # verify insecure=true
kubectl port-forward -n argocd svc/argocd-server 8080:443      # fallback
```

**Reset everything**
```bash
./setup.sh   # option 10 — Delete cluster
./setup.sh   # option 1  — Full deploy
```

## License

MIT
