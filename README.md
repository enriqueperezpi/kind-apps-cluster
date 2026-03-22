# kind-apps-cluster

Local Kubernetes cluster with ArgoCD, Gateway API (Cilium), and cert-manager — all managed by an idempotent bash script.

## Architecture

> Editable diagram: [`docs/architecture.drawio`](docs/architecture.drawio) — open in [draw.io](https://app.diagrams.net/).

![Architecture diagram](./docs/architecture.drawio.png)


### How traffic reaches ArgoCD

```
Browser ──► localhost:8080
                │
                ▼
        kubectl port-forward
                │
                ▼
        argocd-server Service (:443)
                │
                ▼
        ArgoCD Pod (HTTP, insecure mode)
```

The Gateway API (Cilium) handles **in-cluster routing** for deployed applications. External access to ArgoCD uses `kubectl port-forward` — no host routes, no sudo, works on every OS.

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
./setup.sh          # interactive menu
./setup.sh -y       # non-interactive full deploy
```

After the deploy completes, select **option 9** to start port-forward and open `http://localhost:8080`.

## Usage

### Interactive Menu

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

### Custom Config File

```bash
./setup.sh /path/to/my-config.conf
```

## Accessing ArgoCD

```bash
./setup.sh   # option 9 — Port-forward ArgoCD
```

Opens a tunnel: `localhost:8080 → argocd-server:443`. Press Ctrl+C to stop.

- **URL:** `http://localhost:8080`
- **User:** `admin`
- **Password:** shown after deploy (or `./setup.sh` → option 8)

## Configuration (`config.conf`)

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
| `HTTP_PORT` | `80` | Host port mapped to kind node |
| `HTTPS_PORT` | `443` | Host port mapped to kind node |

## Components

| Component | Purpose |
|-----------|---------|
| **kind** | Local K8s cluster running in Docker |
| **Cilium** | CNI + Gateway API controller (replaces kube-proxy and nginx-ingress) |
| **Gateway API** | Standard ingress (`Gateway`, `HTTPRoute` CRDs) — Cilium is the controller |
| **cert-manager** | Certificate management with selfsigned `ClusterIssuer` for local dev |
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
│   ├── gateway-api.sh      # Gateway API CRDs + Cilium
│   └── cert-manager.sh     # cert-manager + ClusterIssuer
├── argocd-apps/
│   ├── README.md
│   └── example-guestbook.yaml
└── docs/
    └── architecture.drawio  # Editable diagram (open in draw.io)
```

## Idempotency

The script is safe to re-run at any time:

- **Cluster**: detects unhealthy containers and recreates automatically.
- **Helm charts** (Cilium, cert-manager): `helm upgrade --install` reconciles to desired state.
- **ArgoCD**: config set via `argocd-cmd-params-cm` ConfigMap + rollout restart.
- **ArgoCD apps**: `kubectl apply` is naturally idempotent.

## Troubleshooting

**Docker not running**
```
ERROR: failed to create cluster: could not find a container runtime
```
→ Start Docker Desktop or your container runtime.

**Ports 80/443 in use**
→ Edit `HTTP_PORT` / `HTTPS_PORT` in `config.conf`.

**ArgoCD UI not loading**
```bash
kubectl get pods -n argocd                                     # check pods
kubectl get configmap argocd-cmd-params-cm -n argocd -o yaml  # verify insecure=true
kubectl port-forward -n argocd svc/argocd-server 8080:443     # manual port-forward
```

**Gateway API not routing**
```bash
kubectl get gateway -A        # check Gateway status
kubectl get httproute -A      # check HTTPRoute status
kubectl get pods -n kube-system -l k8s-app=cilium  # check Cilium pods
```

**Reset everything**
```bash
./setup.sh   # option 10 — Delete cluster
./setup.sh   # option 1  — Full deploy
```

## License

MIT
