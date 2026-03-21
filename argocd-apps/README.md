# ArgoCD Application examples
# ============================
# Drop any Application or ApplicationSet YAML files here.
# They will be applied by setup.sh option 6 (or during full deploy).
#
# Structure follows standard ArgoCD Application CRD:
#   apiVersion: argoproj.io/v1alpha1
#   kind: Application       # or ApplicationSet
#   metadata:
#     name: my-app
#     namespace: argocd
#   spec:
#     project: default
#     source:
#       repoURL: <git-repo>
#       targetRevision: <branch-or-tag>
#       path: <path-in-repo>
#     destination:
#       server: https://kubernetes.default.svc
#       namespace: <target-ns>
#     syncPolicy:
#       automated:
#         prune: true
#         selfHeal: true
#
# See example-guestbook.yaml for a working example.
