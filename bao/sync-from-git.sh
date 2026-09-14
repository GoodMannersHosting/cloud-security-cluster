#!/usr/bin/env bash
# Apply policies and auth roles from this directory (CI or local with BAO_TOKEN).
# Supports root namespace and namespaced policies/roles in bao/namespaces/<ns>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAO_AUTH_MOUNT="${BAO_AUTH_MOUNT:-${GITHUB_JWT_MOUNT:-jwt}}"

die() { echo "error: $*" >&2; exit 1; }

require_token() {
  export BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
  export BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN:-}}"
  # If no explicit token, verify bao CLI is authenticated
  if [[ -z "${BAO_TOKEN}" ]]; then
    if ! bao status >/dev/null 2>&1; then
      die "bao CLI not authenticated (BAO_TOKEN or VAULT_TOKEN required, or run 'bao login')"
    fi
  fi
}

subst_client_id() {
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1]))
doc['bound_audiences'] = [sys.argv[2]]
json.dump(doc, sys.stdout)
" "$1" "$2"
}

# Write root namespace policies
write_policies() {
  echo "==> policies (root)"
  for policy in "$ROOT/policies/"*.hcl; do
    [[ -f "$policy" ]] || continue
    name="$(basename "$policy" .hcl)"
    bao policy write "$name" "$policy"
  done
}

# Write root namespace OIDC roles
write_oidc_roles() {
  [[ -n "${AUTHENTIK_CLIENT_ID:-}" ]] || {
    echo "==> skip oidc roles (AUTHENTIK_CLIENT_ID unset)"
    return
  }
  echo "==> oidc roles (root)"
  for role in admin reader operator; do
    subst_client_id "$ROOT/roles/${role}.json" "$AUTHENTIK_CLIENT_ID" \
      | bao write "auth/oidc/role/${role}" -
  done
}

# Write JWT CI role
write_jwt_ci_role() {
  if [[ ! -f "$ROOT/jwt/github-actions-ci.json" ]]; then
    return
  fi
  local role="${BAO_CI_ROLE:-github-actions-ci}"
  echo "==> jwt role ${role}"
  export ROOT
  export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-GoodMannersHosting/aws-security-cluster}"
  export GITHUB_REF="${GITHUB_REF:-refs/heads/main}"
  export GITHUB_JWT_AUDIENCE="${GITHUB_JWT_AUDIENCE:-${BAO_OIDC_AUDIENCE:-https://github.com/GoodMannersHosting}}"
  python3 - <<PY | bao write "auth/${BAO_AUTH_MOUNT}/role/${role}" -
import json, os, pathlib
root = pathlib.Path(os.environ["ROOT"])
repo = os.environ["GITHUB_REPOSITORY"]
ref = os.environ["GITHUB_REF"]
aud = os.environ["GITHUB_JWT_AUDIENCE"]
doc = json.loads((root / "jwt/github-actions-ci.json").read_text())
doc["bound_audiences"] = [aud]
doc["bound_subject"] = f"repo:{repo}:ref:{ref}"
doc["bound_claims"] = {"repository": repo, "ref": ref}
print(json.dumps(doc))
PY
}

# Write Kubernetes role
write_kubernetes_role() {
  if [[ ! -f "$ROOT/kubernetes/labops-eso-litellm.json" ]]; then
    return
  fi
  local mount="${BAO_K8S_MOUNT:-kubernetes-labops}"
  local role="${BAO_K8S_ROLE:-eso-litellm}"
  echo "==> kubernetes role ${role}"
  if ! bao write "auth/${mount}/role/${role}" @"$ROOT/kubernetes/labops-eso-litellm.json"; then
    echo "warn: could not write auth/${mount}/role/${role} (mount not enabled yet?)" >&2
  fi
}

# Write namespace-specific policies
write_namespace_policies() {
  local ns="$1"
  local ns_dir="$ROOT/namespaces/$ns"
  
  echo "==> policies ($ns)"
  if [[ ! -d "$ns_dir/policies" ]]; then
    echo "  skip (no policies dir)"
    return
  fi
  for policy in "$ns_dir/policies/"*.hcl; do
    [[ -f "$policy" ]] || continue
    name="$(basename "$policy" .hcl)"
    bao policy write -namespace="$ns" "$name" "$policy"
  done
}

# Write namespace-specific OIDC roles
write_namespace_oidc_roles() {
  local ns="$1"
  local ns_dir="$ROOT/namespaces/$ns"
  
  echo "==> oidc roles ($ns)"
  [[ -n "${AUTHENTIK_CLIENT_ID:-}" ]] || {
    echo "  skip (AUTHENTIK_CLIENT_ID unset)"
    return
  }
  if [[ ! -d "$ns_dir/roles" ]]; then
    echo "  skip (no roles dir)"
    return
  fi
  for role_file in "$ns_dir/roles/"*.json; do
    [[ -f "$role_file" ]] || continue
    role="$(basename "$role_file" .json)"
    subst_client_id "$role_file" "$AUTHENTIK_CLIENT_ID" \
      | bao write -namespace="$ns" "auth/oidc/role/${role}" -
  done
}

# Sync all namespaces
sync_namespaces() {
  local ns_dir
  for ns_dir in "$ROOT/namespaces/"*/; do
    [[ -d "$ns_dir" ]] || continue
    local ns="$(basename "$ns_dir")"
    echo ""
    echo "=== syncing namespace: $ns ==="
    write_namespace_policies "$ns"
    write_namespace_oidc_roles "$ns"
  done
}

main() {
  command -v bao >/dev/null 2>&1 || die "missing bao CLI"
  require_token
  
  # Root namespace
  write_policies
  write_oidc_roles
  write_jwt_ci_role
  write_kubernetes_role
  
  # Namespace-specific configs
  if [[ -d "$ROOT/namespaces" ]]; then
    sync_namespaces
  fi
  
  echo ""
  echo "done"
}

main "$@"