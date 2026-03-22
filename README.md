# kind-apps-cluster

Local Kubernetes cluster with ArgoCD and Gateway API — all managed by an idempotent bash script.

## Architecture

**Key design:** Uses kind's built-in networking by default. Optionally enables **Cilium CNI** with **Gateway API** for advanced HTTP routing. Works on macOS, Windows, and Linux.

### Default Mode (kind networking)

```
Browser ──► localhost:80 (kind node port)
                  │
                  ▼
         kind cluster (default CNI)
                  │
                  ▼
         ArgoCD Service (ClusterIP:80)
                  │
                  ▼
         ArgoCD Pod (insecure mode)
```

**Access:** `kubectl port-forward -n argocd svc/argocd-server 8080:80`

### Optional: Cilium + Gateway API (Linux only)

```
Browser ──► argocd.local
                  │
                  ▼
         kind cluster with Cilium CNI
      ┌─────────────────────────────────────┐
      │  Cilium Gateway API Controller      │
      │  - Manages Gateway resources        │
      └─────────────────────────────────────┘
                  │
                  ▼
         Gateway + HTTPRoute
      ┌─────────────────────────────────────┐
      │  Gateway: cilium-gateway            │
      │  HTTPRoute: argocd.local → :80      │
      └─────────────────────────────────────┘
                  │
                  ▼
       ArgoCD Service (ClusterIP:80)
```

**Access:** Add `127.0.0.1 argocd.local` to `/etc/hosts`, then visit `http://argocd.local`

**Adding new apps:** Create a HTTPRoute in your app's folder to expose it at `http://appname.local`

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
  1)  Full deploy (cluster + nginx + argocd + apps)
  2)  Create / verify kind cluster only
  3)  Install Nginx reverse proxy (hostNetwork)
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

After deploy completes, Nginx reverse proxy is running as a DaemonSet with hostNetwork and listening on `localhost:80`.

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
| `CNI_PLUGIN` | `kind` | CNI plugin: `kind` (works everywhere) or `cilium` (Gateway API, Linux only) |
| `CILIUM_VERSION` | `1.17.2` | Cilium version (only if CNI_PLUGIN=cilium) |
| `GATEWAY_CLASS_NAME` | `cilium` | Gateway API controller class |
| `ARGOCD_NAMESPACE` | `argocd` | Namespace for ArgoCD and Gateway |
| `ARGOCD_VERSION` | `stable` | ArgoCD manifest version. specific version is possible |
| `ARGOCD_APPS_DIR` | `./argocd-apps` | Directory with Application/ApplicationSet YAMLs |
| `AUTO_INSTALL_TOOLS` | `true` | Auto-install missing CLI tools |
| `HTTP_PORT` | `80` | Host port exposed by kind node |
| `HTTPS_PORT` | `443` | Host port exposed by kind node |

## Components

| Component | Purpose |
|-----------|---------|
| **kind** | Local K8s cluster running in Docker |
| **Cilium** | CNI + Gateway API controller — L4/L7 networking and HTTP routing |
| **Gateway API** | Standard ingress API (Gateway, HTTPRoute CRDs) |
| **ArgoCD** | GitOps continuous delivery — deploys apps from `argocd-apps/` |

## Deploying Applications

Each application gets its own folder under `argocd-apps/` with an `application.yaml` file:

```
argocd-apps/
├── guestbook/
│   ├── application.yaml       # ArgoCD Application CRD
│   └── values.yaml           # Helm values (optional)
└── your-app/
    ├── application.yaml
    └── values.yaml
```

### Quick Example

```yaml
# argocd-apps/my-app/application.yaml
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
    syncOptions:
      - CreateNamespace=true
```

Apps are applied during full deploy or via menu option 5. See [`argocd-apps/README.md`](argocd-apps/README.md) for detailed documentation.

## Project Structure

```
kind-apps-cluster/
├── setup.sh                # Main entry point (menu + non-interactive)
├── config.conf             # All configurable parameters
├── lib/
│   ├── utils.sh           # Logging, wait helpers
│   ├── tools.sh            # Tool detection & installation
│   ├── kind.sh            # kind cluster lifecycle + Cilium config
│   ├── argocd.sh          # ArgoCD install, insecure config, apps deployer
│   └── gateway-api.sh     # Cilium Gateway API controller
├── argocd-apps/           # ArgoCD Application definitions + HTTPRoutes
    ├── README.md          # Apps deployment guide
    ├── guestbook/         # Example app
    │   ├── application.yaml
    │   ├── httproute.yaml
    │   └── values.yaml
    └── (your-apps)/       # Add your apps here
        ├── application.yaml
        ├── httproute.yaml
        └── values.yaml
```

## Idempotency

The script is safe to re-run at any time:

- **Cluster**: detects unhealthy containers and recreates automatically.
- **Cilium**: Helm upgrade reconciles to desired state.
- **Helm charts** (ArgoCD): `helm upgrade --install` reconciles to desired state.
- **HTTPRoutes**: naturally idempotent via `kubectl apply`.
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

# 2. Check Cilium is running
kubectl get pods -n cilium -l k8s-app=cilium

# 3. Check Gateway status
kubectl get gateway cilium-gateway -n argocd

# 4. Check HTTPRoute
kubectl get httproute argocd -n argocd

# 5. Test connectivity
curl -H "Host: argocd.local" http://localhost:80
```

**Cilium not installed or failing**
```bash
# Check Cilium pods
kubectl get pods -n cilium

# View Cilium logs
kubectl logs -n cilium -l k8s-app=cilium --tail=50

# Describe Cilium operator
kubectl describe pods -n cilium -l k8s-app=cilium-operator

# Reinstall Cilium
helm upgrade cilium cilium/cilium --namespace cilium \
  --set gatewayAPI.enabled=true
```

**HTTPRoute not routing**
```bash
# Check HTTPRoute status
kubectl describe httproute argocd -n argocd

# Check if Gateway accepts the route
kubectl get gateway cilium-gateway -n argocd -o yaml | grep -A 10 status

# Check Cilium Gateway API status
cilium gateway status
```

**ArgoCD UI not loading**
```bash
kubectl get pods -n argocd                                     # check all pods
kubectl get configmap argocd-cmd-params-cm -n argocd -o yaml  # verify insecure=true
kubectl port-forward -n argocd svc/argocd-server 8080:80      # manual port-forward
# Then visit http://localhost:8080
```

**DNS not resolving `*.local` on macOS**
```bash
# Flush DNS cache on macOS
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

# Verify /etc/hosts
cat /etc/hosts | grep local
```

**Reset everything**
```bash
./setup.sh   # option 9 — Delete cluster
./setup.sh   # option 1  — Full deploy
```

## License

MIT
