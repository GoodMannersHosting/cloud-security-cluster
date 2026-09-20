#!/usr/bin/env bash
# Apply policies and auth roles from this directory (CI or local with BAO_TOKEN).
# Uses the bao CLI. Supports root namespace and namespaced policies/roles in bao/namespaces/<ns>/.
set -euo pipefail

# Ensure Homebrew/Linuxbrew paths are in PATH
for brew_path in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin; do
  if [[ -d "$brew_path" ]] && [[ ":$PATH:" != *":$brew_path:"* ]]; then
    export PATH="$brew_path:$PATH"
  fi
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
BAO_AUTH_MOUNT="${BAO_AUTH_MOUNT:-${GITHUB_JWT_MOUNT:-jwt}}"

die() { echo "error: $*" >&2; exit 1; }

# Require token and address
require_token() {
  export BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
  export BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN:-}}"
  [[ -n "${BAO_TOKEN}" ]] || die "BAO_TOKEN or VAULT_TOKEN required"
}

# Write policy to root namespace
put_policy() {
  local name="$1"
  local policy_file="$2"
  echo "  writing policy $name"
  bao policy write "$name" "$policy_file"
}

# Write auth role to root namespace
put_auth_role() {
  local mount="$1"
  local role_name="$2"
  local role_json="$3"
  echo "  writing $mount role $role_name"
  echo "$role_json" | bao write "auth/${mount}/role/${role_name}" -
}

# Write policy to a specific namespace
put_policy_ns() {
  local ns="$1"
  local name="$2"
  local policy_file="$3"
  echo "  writing policy $name to namespace $ns"
  bao -namespace="$ns" policy write "$name" "$policy_file"
}

# Write auth role to a specific namespace
put_auth_role_ns() {
  local ns="$1"
  local mount="$2"
  local role_name="$3"
  local role_json="$4"
  echo "  writing $mount role $role_name to namespace $ns"
  echo "$role_json" | bao -namespace="$ns" write "auth/${mount}/role/${role_name}" -
}

# Substitute Authentik client ID in role JSON
subst_client_id() {
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1]))
doc['bound_audiences'] = [sys.argv[2]]
json.dump(doc, sys.stdout)
" "$1" "${AUTHENTIK_CLIENT_ID:-}"
}

# Write root namespace policies
write_policies() {
  echo "==> policies (root)"
  local policies_found=0
  for policy in "$ROOT/policies/"*.hcl; do
    [[ -f "$policy" ]] || continue
    policies_found=1
    name="$(basename "$policy" .hcl)"
    put_policy "$name" "$policy"
  done
  if [[ "$policies_found" -eq 0 ]]; then
    echo "  skip (no policies)"
  fi
}

# Write root namespace OIDC roles
write_oidc_roles() {
  [[ -n "${AUTHENTIK_CLIENT_ID:-}" ]] || {
    echo "==> skip oidc roles (AUTHENTIK_CLIENT_ID unset)"
    return
  }
  echo "==> oidc roles (root)"
  local roles_found=0
  for role in admin reader operator; do
    local role_file="$ROOT/roles/${role}.json"
    [[ -f "$role_file" ]] || continue
    roles_found=1
    local role_json
    role_json=$(subst_client_id "$role_file")
    put_auth_role "oidc" "$role" "$role_json"
  done
  if [[ "$roles_found" -eq 0 ]]; then
    echo "  skip (no roles)"
  fi
}

# Write JWT CI role
write_jwt_ci_role() {
  if [[ ! -f "$ROOT/jwt/github-actions-ci.json" ]]; then
    return
  fi
  local role="${BAO_CI_ROLE:-github-actions-ci}"
  echo "==> jwt role ${role}"
  local role_json
  role_json=$(python3 - <<'PY'
import json, pathlib
root = pathlib.Path(".") / "bao"
aud = "https://github.com/GoodMannersHosting"
doc = json.loads((root / "jwt/github-actions-ci.json").read_text())
doc["bound_audiences"] = [aud]
if "bound_claims" in doc:
    doc["bound_claims_type"] = "string"
if "bound_subject" in doc:
    del doc["bound_subject"]
print(json.dumps(doc))
PY
)
  put_auth_role "$BAO_AUTH_MOUNT" "$role" "$role_json"
}

# Write Kubernetes role
write_kubernetes_role() {
  if [[ ! -f "$ROOT/kubernetes/labops-eso-litellm.json" ]]; then
    return
  fi
  local mount="${BAO_K8S_MOUNT:-kubernetes-labops}"
  local role="${BAO_K8S_ROLE:-eso-litellm}"
  echo "==> kubernetes role ${role}"
  local role_json
  role_json=$(cat "$ROOT/kubernetes/labops-eso-litellm.json")
  put_auth_role "$mount" "$role" "$role_json"
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
  
  local policies_found=0
  for policy in "$ns_dir/policies/"*.hcl; do
    [[ -f "$policy" ]] || continue
    policies_found=1
    name="$(basename "$policy" .hcl)"
    put_policy_ns "$ns" "$name" "$policy"
  done
  if [[ "$policies_found" -eq 0 ]]; then
    echo "  skip (no policies)"
  fi
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
  
  local roles_found=0
  for role_file in "$ns_dir/roles/"*.json; do
    [[ -f "$role_file" ]] || continue
    roles_found=1
    role="$(basename "$role_file" .json)"
    local role_json
    role_json=$(subst_client_id "$role_file")
    put_auth_role_ns "$ns" "oidc" "$role" "$role_json"
  done
  if [[ "$roles_found" -eq 0 ]]; then
    echo "  skip (no roles)"
  fi
}

# Sync all namespaces
sync_namespaces() {
  if [[ ! -d "$ROOT/namespaces" ]]; then
    return
  fi
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
  command -v python3 >/dev/null 2>&1 || die "missing python3"
  require_token
  
  # Root namespace
  write_policies
  write_oidc_roles
  write_jwt_ci_role
  write_kubernetes_role
  
  # Namespace-specific configs
  sync_namespaces
  
  echo ""
  echo "done"
}

main "$@"
