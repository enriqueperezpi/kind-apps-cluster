# kind-apps-cluster

Local Kubernetes cluster with ArgoCD, Gateway API (Cilium), and cert-manager — all managed by an idempotent bash script.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  kind cluster (localhost)                           │
│                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────┐  │
│  │   Cilium    │  │ cert-manager │  │  ArgoCD   │  │
│  │ Gateway API │  │  (selfsigned)│  │  (server) │  │
│  └──────┬──────┘  └──────────────┘  └─────┬─────┘  │
│         │                                  │        │
│         └── HTTPRoute ─────────────────────┘        │
│                                                     │
│  http://argocd.localtest.me ──> ArgoCD UI           │
└─────────────────────────────────────────────────────┘
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

After the full deploy completes you will see the ArgoCD admin password and URL in the terminal.

## Usage

### Interactive Menu

Run `./setup.sh` to get the menu:

```
  1) Full deploy (cluster + gateway + cert-mgr + argocd + apps)
  2) Create / verify kind cluster only
  3) Install Gateway API + Cilium
  4) Install cert-manager
  5) Install ArgoCD
  6) Apply ArgoCD applications from ./argocd-apps
  7) Show status of all components
  8) Get ArgoCD admin password
  9) Delete cluster
  0) Exit
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

## Configuration (`config.conf`)

All parameters live in `config.conf` and can be overridden with environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `kind-apps-cluster` | kind cluster name |
| `K8S_VERSION` | `v1.31.0` | Kubernetes version (kind node image tag) |
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

### ArgoCD UI

Open **http://argocd.localtest.me** in your browser.

The `*.localtest.me` domain resolves to `127.0.0.1` automatically — no `/etc/hosts` changes needed.

Credentials:
- **User:** `admin`
- **Password:** shown after deploy (or run `./setup.sh` → option 8)

## Project Structure

```
kind-apps-cluster/
├── setup.sh              # Main entry point (menu + non-interactive)
├── config.conf           # All configurable parameters
├── lib/
│   ├── utils.sh          # Logging, wait helpers
│   ├── tools.sh          # Tool detection & installation
│   ├── kind.sh           # kind cluster lifecycle
│   ├── argocd.sh         # ArgoCD install, patch, app apply
│   ├── gateway-api.sh    # Gateway API CRDs + Cilium + HTTPRoute
│   └── cert-manager.sh   # cert-manager + ClusterIssuer
└── argocd-apps/
    ├── README.md
    └── example-guestbook.yaml
```

## Idempotency

The script is designed to be re-run safely at any time:

- **Cluster**: skips creation if it already exists.
- **Helm charts** (Cilium, cert-manager): uses `helm upgrade --install` — reconciles to desired state.
- **ArgoCD**: applies the manifest (kubectl apply is naturally idempotent).
- **ArgoCD apps**: applies YAMLs with `kubectl apply`.

## Troubleshooting

**Docker not running**
```
ERROR: failed to create cluster: could not find a container runtime
```
→ Start Docker Desktop or your container runtime.

**Ports 80/443 in use**
→ Edit `HTTP_PORT` / `HTTPS_PORT` in `config.conf`.

**Cilium gateway not routing**
```bash
cilium status --wait          # from inside the cluster
kubectl get gateway -A        # check gateway status
kubectl get httproute -A      # check route status
```

**Reset everything**
```bash
./setup.sh   # option 9 — Delete cluster
./setup.sh   # option 1 — Full deploy
```

## License

MIT
