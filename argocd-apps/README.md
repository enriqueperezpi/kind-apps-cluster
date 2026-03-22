# ArgoCD Applications

This directory contains ArgoCD Application definitions for GitOps-managed workloads, plus optional Gateway API routing configurations.

## Architecture

```
Browser ──► Host:80 ──► Cilium Gateway ──► HTTPRoute ──► Service ──► Pod
                    (Gateway API Controller)
```

- **Cilium** handles networking and Gateway API routing
- **HTTPRoutes** define HTTP routing rules per app
- **Apps** are deployed by ArgoCD and exposed via HTTPRoutes

## Directory Structure

```
argocd-apps/
├── README.md                    # This file
├── guestbook/                   # Example app
│   ├── application.yaml        # ArgoCD Application CRD
│   ├── httproute.yaml          # Gateway API routing (optional)
│   └── values.yaml             # Helm values (optional)
└── your-app/                   # Your app
    ├── application.yaml        # ArgoCD Application CRD
    ├── httproute.yaml          # Gateway API routing (optional)
    └── values.yaml             # Helm values (optional)
```

## Adding Applications

### 1. Create app directory

```bash
mkdir -p argocd-apps/your-app
```

### 2. Create ArgoCD Application CRD

```yaml
# argocd-apps/your-app/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: your-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: deploy/k8s
    # For Helm charts, uncomment:
    # helm:
    #   valueFiles:
    #     - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: your-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 3. (Optional) Create HTTPRoute for public access

```yaml
# argocd-apps/your-app/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: your-app
  namespace: your-app
spec:
  parentRefs:
  - name: cilium-gateway
    namespace: argocd
  hostnames:
  - "your-app.local"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: your-app-service
      port: 80
```

### 4. (Optional) Add Helm values

```yaml
# argocd-apps/your-app/values.yaml
replicaCount: 2

image:
  repository: your-image
  tag: latest

service:
  type: ClusterIP
  port: 8080
```

## Gateway API Routing

Apps that want to be publicly accessible via `http://appname.local` need a **HTTPRoute**.

### HTTPRoute Fields Explained

| Field | Description |
|-------|-------------|
| `parentRefs` | Links to the Gateway (`cilium-gateway` in `argocd` namespace) |
| `hostnames` | DNS names to match (add to `/etc/hosts`) |
| `rules` | Routing rules with path matching |
| `backendRefs` | Target service and port |

### Multiple Paths

```yaml
spec:
  rules:
  - matches:
    - path:
        type: Exact
        value: /api
    backendRefs:
    - name: api-service
      port: 8080
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-service
      port: 80
```

## Deploying Apps

Apps are deployed automatically during:
- Full deploy (`./setup.sh -y`)
- Interactive menu option 5

Or manually:
```bash
# Apply ArgoCD Applications
kubectl apply -f argocd-apps/your-app/application.yaml

# Apply HTTPRoutes
kubectl apply -f argocd-apps/your-app/httproute.yaml

# List apps in ArgoCD
argocd app list

# Sync an app
argocd app sync your-app
```

## Accessing Apps

After deploying with HTTPRoute:

```bash
# 1. Add to /etc/hosts
echo "127.0.0.1 your-app.local" | sudo tee -a /etc/hosts

# 2. Visit in browser
http://your-app.local
```

## Removing an App

```bash
# Delete ArgoCD Application
kubectl delete -f argocd-apps/your-app/application.yaml

# Delete HTTPRoute (if exists)
kubectl delete -f argocd-apps/your-app/httproute.yaml

# Remove directory
rm -rf argocd-apps/your-app
```

## Best Practices

1. **One directory per app** — Keeps resources organized
2. **Use namespaces** — Each app in its own namespace
3. **Sync policy** — Enable `prune` and `selfHeal` for GitOps
4. **HTTPRoutes** — Only create if app needs public access
5. **Helm values** — Keep in app directory for portability
6. **DNS** — Update `/etc/hosts` for each new hostname

## Example Apps

- **guestbook/** — Simple web app with HTTPRoute for routing

## Troubleshooting

```bash
# Check Gateway status
kubectl get gateway cilium-gateway -n argocd

# Check HTTPRoutes
kubectl get httproute --all-namespaces

# Describe HTTPRoute
kubectl describe httproute your-app -n your-app

# Check Cilium pods
kubectl get pods -n cilium

# View Cilium Gateway status
cilium gateway status
```
