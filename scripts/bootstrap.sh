#!/usr/bin/env bash

# Bootstrap an appstack ArgoCD deployment.
# Designed to be idempotent — safe to run multiple times.
#
# Configuration precedence:
# 1. Defaults defined in this script
# 2. Variables from $PWD/.env if it exists
# 3. Flags explicitly passed to this script
#
# Sensitive credentials (INFISICAL_UNIVERSAL_AUTH_CLIENT_ID,
# INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET) are read from environment variables only.

set -euo pipefail

STACK_NAME="appstack"
CLUSTER_NAME="k3d-lab-$(hostname)"
CLUSTER_DOMAIN=""
CHART_REPO=""   # e.g. oci://ghcr.io/your-org/helm
CHART_VERSION=""

# Derive a default HTTPS repo URL from the git remote, converting SSH format if needed
_remote=$(git remote get-url origin 2>/dev/null || true)
if [[ "$_remote" == https://* ]]; then
  REPO_URL="$_remote"
elif [[ "$_remote" == git@* ]]; then
  REPO_URL=$(echo "$_remote" | sed 's|git@\([^:]*\):\(.*\)|https://\1/\2|')
else
  REPO_URL=""
fi
BOOTSTRAP_NS="argocd"
TARGET_REVISION="main"
SSH_KEY_FILE=""
INFISICAL_PROJECT=""
INFISICAL_PATH=""
AUTO_SYNC=false
OAUTH_ENABLED=false

log() {
  >&2 echo "$@"
}

die() {
  log "error: $*"
  exit 1
}

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --name <name>               Stack name — used as ArgoCD project name and resource prefix (default: appstack)
  --chart-repo <url>          OCI URL of the Helm chart repository (required; e.g. oci://ghcr.io/your-org/helm)
  --chart-version <version>   Version of the appstack charts to install (required)
  --repo-url <url>            HTTPS URL of this repository (required; used for ArgoCD source and repo credentials)
  --cluster <name>            Cluster name (default: k3d-lab-<hostname>)
  --domain <domain>           Cluster domain (default: <cluster-name>.local)
  --namespace <ns>            ArgoCD namespace (default: argocd)
  --version <rev>             Git target revision (default: main)
  --ssh-key <path>            SSH private key for ArgoCD repo access (default: ~/.ssh/id_ed25519)
  --infisical-project <slug>  Infisical project slug; enables Infisical integration
  --infisical-path <path>     Infisical secrets path for the ClusterSecretStore
  --auto-sync                 Enable ArgoCD auto-sync (default: off)
  --oauth                     Enable OAuth ingress protection (requires a cluster-level OAuth proxy)

Environment variables:
  GITHUB_TOKEN                            Required — used for ArgoCD repo access and Helm OCI registry auth
  INFISICAL_UNIVERSAL_AUTH_CLIENT_ID      Required when --infisical-project is set
  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET  Required when --infisical-project is set

  When using the kubernetes backend (default), app credentials are seeded into the
  local-secrets namespace. Add your app-specific secrets to the SECRETS_ARGS array
  below, or populate them manually before running ArgoCD sync.
EOF
}

# Load .env if present
if [[ -f "$PWD/.env" ]]; then
  log "Loading $PWD/.env"
  # shellcheck disable=SC1091
  source "$PWD/.env"
fi

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)               STACK_NAME="$2";        shift 2 ;;
    --chart-repo)         CHART_REPO="$2";        shift 2 ;;
    --chart-version)      CHART_VERSION="$2";     shift 2 ;;
    --repo-url)           REPO_URL="$2";           shift 2 ;;
    --cluster)            CLUSTER_NAME="$2";       shift 2 ;;
    --domain)             CLUSTER_DOMAIN="$2";     shift 2 ;;
    --namespace)          BOOTSTRAP_NS="$2";       shift 2 ;;
    --version)            TARGET_REVISION="$2";    shift 2 ;;
    --ssh-key)            SSH_KEY_FILE="$2";       shift 2 ;;
    --infisical-project)  INFISICAL_PROJECT="$2";  shift 2 ;;
    --infisical-path)     INFISICAL_PATH="$2";     shift 2 ;;
    --auto-sync)          AUTO_SYNC=true;          shift   ;;
    --oauth)              OAUTH_ENABLED=true;      shift   ;;
    --help|-h)            usage; exit 0 ;;
    *) die "unknown option: $1. Run with --help for usage." ;;
  esac
done

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-${CLUSTER_NAME}.local}"
BOOTSTRAP_RELEASE="bootstrap-${STACK_NAME}"
LOCAL_SECRETS_NS="${STACK_NAME}-secrets"

# Validate chart coordinates
[[ -z "$CHART_REPO" ]]    && die "--chart-repo is required (e.g. oci://ghcr.io/your-org/helm)"
[[ -z "$CHART_VERSION" ]] && die "--chart-version is required"

# Validate repo URL — must be set and must use HTTPS (repo credentials use HTTP basic auth)
[[ -z "$REPO_URL" ]] && die "--repo-url is required"
[[ "$REPO_URL" == https://* ]] || die "--repo-url must use HTTPS (got: $REPO_URL)"

# Validate required credentials
[[ -z "${GITHUB_TOKEN:-}" ]] && die "GITHUB_TOKEN is required"
GITHUB_USER=$(git config user.name 2>/dev/null || true)
[[ -z "$GITHUB_USER" ]] && die "git user.name is not set — run: git config --global user.name '<your name>'"

# Resolve SSH key
if [[ -z "$SSH_KEY_FILE" ]]; then
  for candidate in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
    if [[ -f "$candidate" ]]; then
      SSH_KEY_FILE="$candidate"
      break
    fi
  done
fi
[[ -z "$SSH_KEY_FILE" ]] && die "no SSH key found; set --ssh-key or create ~/.ssh/id_ed25519"
[[ -f "$SSH_KEY_FILE" ]] || die "SSH key not found: $SSH_KEY_FILE"

if [[ -n "$INFISICAL_PROJECT" ]]; then
  [[ -z "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:-}" ]]     && die "INFISICAL_PROJECT is set but INFISICAL_UNIVERSAL_AUTH_CLIENT_ID is not"
  [[ -z "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}" ]] && die "INFISICAL_PROJECT is set but INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET is not"
  [[ -z "$INFISICAL_PATH" ]]                             && die "INFISICAL_PROJECT is set but --infisical-path is not"
fi

BACKEND="kubernetes"
[[ -n "$INFISICAL_PROJECT" ]] && BACKEND="infisical"

log "Bootstrapping appstack"
log "  stack:     $STACK_NAME"
log "  repo:      $REPO_URL"
log "  cluster:   $CLUSTER_NAME"
log "  domain:    $CLUSTER_DOMAIN"
log "  revision:  $TARGET_REVISION"
log "  backend:   $BACKEND"
log "  auto-sync: $AUTO_SYNC"
log "  oauth:     $OAUTH_ENABLED"
log "  gh-user:   $GITHUB_USER"
[[ "$BACKEND" == "infisical" ]] && log "  infisical: $INFISICAL_PROJECT ($INFISICAL_PATH)"

if [[ "$BACKEND" == "infisical" ]]; then
  log "Creating Infisical credentials secret..."

  SECRETS_ARGS=(
    upgrade --install "${STACK_NAME}-secrets" "${CHART_REPO}/argo-appstack-secrets"
    --version "$CHART_VERSION"
    --namespace external-secrets
    --create-namespace
    --set "backend=$BACKEND"
    --set "universalAuth.clientId=$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID"
    --set "universalAuth.clientSecret=$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"
  )
else
  log "Seeding local-secrets namespace (${LOCAL_SECRETS_NS})..."

  # Add app-specific secrets here as additional --set flags, e.g.:
  #   --set "localSecrets.secrets.my-app-creds.API_KEY=${MY_APP_API_KEY:-}"
  SECRETS_ARGS=(
    upgrade --install "${STACK_NAME}-secrets" "${CHART_REPO}/argo-appstack-secrets"
    --version "$CHART_VERSION"
    --namespace "$LOCAL_SECRETS_NS"
    --create-namespace
    --set "localSecrets.namespace=${LOCAL_SECRETS_NS}"
  )
fi

helm "${SECRETS_ARGS[@]}"

HELM_ARGS=(
  upgrade --install "$BOOTSTRAP_RELEASE" "${CHART_REPO}/argo-appstack"
  --version "$CHART_VERSION"
  --namespace "$BOOTSTRAP_NS"
  --create-namespace
  --set "stack.name=$STACK_NAME"
  --set "autosync.enabled=$AUTO_SYNC"
  --set "cluster.name=$CLUSTER_NAME"
  --set "cluster.domain=$CLUSTER_DOMAIN"
  --set "source.repoURL=$REPO_URL"
  --set "source.targetRevision=$TARGET_REVISION"
  --set "source.username=$GITHUB_USER"
  --set "source.password=$GITHUB_TOKEN"
  --set "secrets.backend.kubernetes.namespace=${LOCAL_SECRETS_NS}"
)

if [[ "$BACKEND" == "infisical" ]]; then
  HELM_ARGS+=(
    --set "secrets.backend.infisical.projectSlug=$INFISICAL_PROJECT"
    --set "secrets.backend.infisical.secretsPath=$INFISICAL_PATH"
  )
fi

[[ "$OAUTH_ENABLED" == "true" ]] && HELM_ARGS+=(--set "oauth.enabled=true")

helm "${HELM_ARGS[@]}"
