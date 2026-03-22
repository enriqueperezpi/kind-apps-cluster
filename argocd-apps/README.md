# ArgoCD Applications

This directory contains ArgoCD Application definitions for GitOps-managed workloads.

## Directory Structure

```
argocd-apps/
├── README.md                  # This file
├── guestbook/                 # Example app
│   ├── application.yaml       # ArgoCD Application CRD
│   └── values.yaml           # Helm values (optional, if using Helm)
└── your-app/                  # Your app
    ├── application.yaml       # ArgoCD Application CRD
    ├── values.yaml           # Helm values (optional)
    └── (other configs)        # Any additional K8s manifests
```

## Adding Applications

### 1. Create an app directory

```bash
mkdir -p argocd-apps/your-app
```

### 2. Create an Application CRD

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
    #   parameters:              # Optional overrides
    #     - name: replicaCount
    #       value: "2"
  destination:
    server: https://kubernetes.default.svc
    namespace: your-app-namespace
  syncPolicy:
    automated:
      prune: true    # Remove old resources
      selfHeal: true # Auto-sync drift
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### 3. (Optional) Add Helm values

```yaml
# argocd-apps/your-app/values.yaml
replicaCount: 2

image:
  repository: your-image
  tag: latest

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: true
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
  hosts:
    - host: your-app.local
      paths:
        - path: /
          pathType: Prefix
```

### 4. (Optional) Add other K8s resources

You can include any additional Kubernetes manifests in the app directory:

```
argocd-apps/your-app/
├── application.yaml
├── values.yaml
├── configmap.yaml    # Additional ConfigMaps
├── secret.yaml       # Secrets (use SealedSecrets in prod!)
└── networkpolicy.yaml
```

## Deploying Apps

Apps are deployed automatically during:
- Full deploy (`./setup.sh -y`)
- Interactive menu option 5

Or manually:
```bash
# List apps
argocd app list

# Sync an app
argocd app sync your-app

# View app status
argocd app get your-app
```

## Removing an App

```bash
# Delete the Application CRD
kubectl delete -f argocd-apps/your-app/application.yaml

# Remove the directory
rm -rf argocd-apps/your-app
```

## Best Practices

1. **One app per directory** — Keeps things organized
2. **Use namespaces** — Create dedicated namespaces per app
3. **Sync policy** — Enable `prune` and `selfHeal` for auto-remediation
4. **Helm values** — Keep values in the app directory for portability
5. **ServerSideApply** — Use for better field ownership tracking
6. **Secrets** — Never commit raw secrets; use SealedSecrets or external secrets

## Example Apps

- **guestbook/** — Simple web app from ArgoCD examples (git-sourced manifests)

## Accessing Deployed Apps

Apps deployed to the cluster are accessible at `http://<app-name>.local` if:
1. Added to `/etc/hosts`: `127.0.0.1 your-app.local`
2. Nginx reverse proxy routes to the app's service

For services not exposed via Nginx, use:
```bash
kubectl port-forward svc/your-service 8080:80
# Then visit http://localhost:8080
```
