# appstack-template

GitHub repository template for GitOps-managed application stacks using ArgoCD app-of-apps.

## What's included

- **ArgoCD app-of-apps** — root Application bootstrapped via Helm, managing child Applications from `apps/`
- **External Secrets Operator integration** — ClusterSecretStore supporting Kubernetes-native (local dev) and Infisical backends
- **Authelia** — optional OAuth2 proxy for ingress protection (`helm/authelia/`)
- **Idempotent bootstrap script** — `scripts/bootstrap.sh` brings up the full stack from scratch

## Repository structure

```
├── apps/                     # App-of-apps Helm chart — add your Application manifests here
│   └── templates/
│       ├── _example.yaml     # Commented example showing the multi-source Application pattern
│       └── secret-store.yaml # ClusterSecretStore Application (deployed automatically)
├── charts/
│   ├── appstack-apps/        # Root bootstrap chart — deploys the ArgoCD Application
│   └── appstack-secrets/     # Secrets bootstrap chart — seeds credentials before ArgoCD takes over
├── manifests/
│   └── secret-store/         # Helm chart for ClusterSecretStore + RBAC (deployed by ArgoCD)
├── helm/
│   └── authelia/             # Authelia values and user database for OAuth ingress protection
└── scripts/
    └── bootstrap.sh          # One-shot cluster bootstrap
```

## Prerequisites

- `kubectl` configured against your target cluster
- `helm` >= 3.x
- ArgoCD installed in the `argocd` namespace
- External Secrets Operator installed

## Quickstart

```bash
cp .env.example .env
# Edit .env — set GITHUB_TOKEN at minimum

./scripts/bootstrap.sh \
  --name mystack \
  --cluster my-cluster \
  --domain my-cluster.example.com \
  --version main \
  --auto-sync
```

The `--name` flag controls the ArgoCD project name, Application name prefix, ClusterSecretStore name, and the local-secrets namespace (`<name>-secrets`). All other resource names are derived from it.

## Adding applications

Copy `apps/templates/_example.yaml`, uncomment, and adapt. The multi-source pattern lets you combine an external Helm chart with local manifests (ExternalSecrets, RBAC, namespace init) in a single Application — keeping context-specific bindings in this repo alongside the deployment configuration.

## Backends

| Backend | When to use | Setup |
|---|---|---|
| `kubernetes` | Local dev, air-gapped | Secrets seeded by bootstrap script into `<stack>-secrets` namespace |
| `infisical` | Production | Pass `--infisical-project` and set `INFISICAL_UNIVERSAL_AUTH_*` env vars |

## OAuth protection

Pass `--oauth` to bootstrap.sh to enable Authelia-based ingress protection. Update `helm/authelia/values.yaml` with your cluster domain before deploying. Applications opt in by including the nginx auth annotations (see `apps/templates/_example.yaml`).
