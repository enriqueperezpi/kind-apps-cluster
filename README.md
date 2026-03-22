# kind-apps-cluster

Local Kubernetes cluster with ArgoCD and Envoy ingress — all managed by an idempotent bash script.

## Architecture

> Editable diagram: [`docs/architecture.drawio`](docs/architecture.drawio) — open in [draw.io](https://app.diagrams.net/).

**Key design:** Uses **Envoy reverse proxy as NodePort service** to route traffic from the host to services in the cluster. Works seamlessly on macOS, Windows, and Linux.

### How traffic reaches ArgoCD

```
Browser ──► localhost:80 (host machine)
                 │
                 ▼
    kind cluster port mapping (80 → NodePort)
                 │
                 ▼
        Envoy Reverse Proxy (NodePort)
                 │
                 ▼
      argocd-server Service (port 80)
                 │
                 ▼
     ArgoCD Pod (HTTP, insecure mode)
```

**Access:** Add `127.0.0.1 argocd.local` to `/etc/hosts` and visit `http://argocd.local`

Envoy handles **routing from external requests to internal services**. The NodePort service exposes Envoy on port 80 (HTTP) and 443 (HTTPS) on all cluster nodes, which kind maps to the host machine.

**To add more services:** Create new backend clusters in the Envoy ConfigMap and route hostnames to them.

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

# 3. Run full deploy
./setup.sh                          # interactive menu
./setup.sh -y                       # non-interactive full deploy
./setup.sh -f /path/to/config.conf  # use custom config file
./setup.sh -y -f config-prod.conf   # non-interactive with custom config
```

After the deploy completes:
1. Add to `/etc/hosts`: `127.0.0.1 argocd.local`
2. Visit `http://argocd.local`
3. Login with credentials shown in deploy output

## Usage

### Interactive Menu

```
  1)  Full deploy (cluster + gateway + argocd + apps)
  2)  Create / verify kind cluster only
  3)  Install Gateway API + cloud-provider-kind
  4)  Install ArgoCD
  5)  Apply ArgoCD applications from ./argocd-apps
  6)  Show status of all components
  7)  Get ArgoCD admin password
  8)  Port-forward ArgoCD (http://localhost:8080)
  9)  Delete cluster
  0)  Exit
```

Every option is **idempotent** — you can run any of them multiple times safely.

### Command-Line Flags

```bash
# Non-interactive mode (automatic full deploy)
./setup.sh -y

# Custom config file
./setup.sh -f /path/to/config.conf

# Combine flags
./setup.sh -y -f staging-config.conf
```

Available flags:
- `-y, --yes` : Skip interactive menu and run full deploy automatically
- `-f, --config <file>` : Use custom configuration file instead of `config.conf`

## Accessing ArgoCD

After deploy completes, Envoy reverse proxy is running as a NodePort service and listening on `localhost:80`.

**Quick Setup:**
```bash
# 1. Add to /etc/hosts
echo "127.0.0.1 argocd.local" | sudo tee -a /etc/hosts

# 2. Visit http://argocd.local
# 3. Login with admin credentials (shown in deploy output)
```

**Get ArgoCD admin password:**
```bash
./setup.sh   # option 7 — Get ArgoCD admin password
```

**Alternative: kubectl Port-Forward (for debugging)**
```bash
./setup.sh   # option 8 — Port-forward ArgoCD to localhost:8080
```
- **URL:** `http://localhost:8080`
- **User:** `admin`
- **Password:** (shown after deploy)

## Configuration (`config.conf`)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `kind-apps-cluster` | kind cluster name |
| `K8S_VERSION` | `v1.33.2` | Kubernetes version (kind node image tag) |
| `WORKER_NODES` | `1` | Number of worker nodes |
| `ARGOCD_NAMESPACE` | `argocd` | Namespace for ArgoCD and Envoy |
| `ARGOCD_VERSION` | `stable` | ArgoCD manifest version |
| `ARGOCD_APPS_DIR` | `./argocd-apps` | Directory with Application/ApplicationSet YAMLs |
| `AUTO_INSTALL_TOOLS` | `true` | Auto-install missing CLI tools |
| `HTTP_PORT` | `80` | Host port mapped to Envoy NodePort |
| `HTTPS_PORT` | `443` | Host port mapped to Envoy NodePort (future) |

## Components

| Component | Purpose |
|-----------|---------|
| **kind** | Local K8s cluster running in Docker |
| **Envoy** | Reverse proxy for HTTP/HTTPS routing — deployed as NodePort service on port 80/443 |
| **ArgoCD** | GitOps continuous delivery — deploys apps from `argocd-apps/` |

## Deploying Applications

Drop `Application` or `ApplicationSet` YAML files into `argocd-apps/`. They are applied during full deploy or via menu option 6.

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

## Project Structure

```
kind-apps-cluster/
├── setup.sh                # Main entry point (menu + non-interactive)
├── config.conf             # All configurable parameters
├── lib/
│   ├── utils.sh            # Logging, wait helpers
│   ├── tools.sh            # Tool detection & installation
│   ├── kind.sh             # kind cluster lifecycle (health checks)
│   ├── argocd.sh           # ArgoCD install, insecure config, port-forward
│   └── gateway-api.sh      # Envoy reverse proxy + NodePort service
├── argocd-apps/
│   ├── README.md
│   └── example-guestbook.yaml
└── docs/
    └── architecture.drawio  # Editable diagram (open in draw.io)
```

## Idempotency

The script is safe to re-run at any time:

- **Cluster**: detects unhealthy containers and recreates automatically.
- **Helm charts** (ArgoCD): `helm upgrade --install` reconciles to desired state.
- **Envoy reverse proxy**: deployment is recreated if unhealthy.
- **ArgoCD**: config set via `argocd-cmd-params-cm` ConfigMap + rollout restart.
- **ArgoCD apps**: `kubectl apply` is naturally idempotent.

## Troubleshooting

**Docker not running**
```
ERROR: failed to create cluster: could not find a container runtime
```
→ Start Docker Desktop or your container runtime.

**Ports 80/443 in use**
→ Edit `HTTP_PORT` / `HTTPS_PORT` in `config.conf` to use different ports (e.g., 8080/8443).

**Cannot reach `argocd.local` after deploy**
```bash
# 1. Verify /etc/hosts entry
grep "argocd.local" /etc/hosts
# Should show: 127.0.0.1 argocd.local

# 2. Verify Envoy is running
kubectl get pods -n argocd -l app=envoy-ingress

# 3. Check Envoy service and NodePort
kubectl get svc envoy-ingress -n argocd

# 4. Verify ArgoCD service is accessible
kubectl get svc argocd-server -n argocd

# 5. Test from within cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://argocd-server.argocd.svc.cluster.local:80
```

**Envoy pod not running or crashing**
```bash
# Check pod status
kubectl describe pod -n argocd -l app=envoy-ingress

# View pod logs
kubectl logs -n argocd -l app=envoy-ingress

# Verify ConfigMap
kubectl get configmap envoy-config -n argocd -o yaml
```

**ArgoCD UI not loading**
```bash
kubectl get pods -n argocd                                     # check all pods
kubectl get configmap argocd-cmd-params-cm -n argocd -o yaml  # verify insecure=true
kubectl port-forward -n argocd svc/argocd-server 8080:80      # manual port-forward
# Then visit http://localhost:8080
```

**DNS not resolving `argocd.local` on macOS**
```bash
# Verify it's in /etc/hosts
cat /etc/hosts | grep argocd.local

# Flush DNS cache on macOS
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

# Test resolution
nslookup argocd.local
```

**Reset everything**
```bash
./setup.sh   # option 9 — Delete cluster
./setup.sh   # option 1  — Full deploy
```

## License

MIT
