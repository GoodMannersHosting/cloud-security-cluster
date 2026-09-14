#!/usr/bin/env bash
# Apply policies and auth roles from this directory (CI or local with BAO_TOKEN).
# Uses raw OpenBao API via curl for all operations (no bao CLI dependency).
# Supports root namespace and namespaced policies/roles in bao/namespaces/<ns>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAO_AUTH_MOUNT="${BAO_AUTH_MOUNT:-${GITHUB_JWT_MOUNT:-jwt}}"

die() { echo "error: $*" >&2; exit 1; }

# Require token and address
require_token() {
  export BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
  export BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN:-}}"
  [[ -n "${BAO_TOKEN}" ]] || die "BAO_TOKEN or VAULT_TOKEN required"
}

# Authenticate in a specific namespace and return a token
# Args: namespace
auth_namespace() {
  local ns="$1"
  echo "  authenticating in namespace $ns"
  
  local response
  response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
    "${BAO_ADDR}/v1/namespace/${ns}/auth/${BAO_AUTH_MOUNT}/login" \
    -H "Content-Type: application/json" \
    -d "{\"role\": \"${BAO_CI_ROLE:-github-actions-ci}\", \"jwt\": \"${OIDC_TOKEN}\"}" \
    --max-time 30)
  
  local http_code
  http_code=$(echo "$response" | grep -oP 'HTTP_CODE:\K\d+')
  local body
  body=$(echo "$response" | grep -v 'HTTP_CODE:')
  
  if [[ "$http_code" -ne 200 ]]; then
    echo "  error: HTTP $http_code" 
    echo "$body" | tail -n 1
    return 1
  fi
  
  local token
  token=$(echo "$body" | python3 -c "
import json, sys
try:
    doc = json.load(sys.stdin)
    print(doc.get('auth', {}).get('client_token', ''))
except:
    print('')
" 2>/dev/null)
  
  [[ -n "$token" ]] || { echo "  error: no token returned"; return 1; }
  echo "$token"
}

# Substitute Authentik client ID in role JSON
subst_client_id() {
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1]))
doc['bound_audiences'] = [sys.argv[2]]
json.dump(doc, sys.stdout)
" "$1" "$2"
}

# PUT policy to specified namespace path
# Args: namespace_path policy_name policy_file
# namespace_path is empty for root, or "namespace/<ns>" for child namespaces
put_policy() {
  local ns_path="$1"
  local name="$2"
  local policy_file="$3"
  local path_prefix=""
  if [[ -n "$ns_path" ]]; then
    path_prefix="/$ns_path"
  fi
  
  echo "  writing policy $name${path_prefix:+ to $ns_path}"
  
  local json_body
  json_body=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    content = f.read()
print(json.dumps({'policy': content}))
" "$policy_file")
  
  local response
  response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
    "${BAO_ADDR}/v1${path_prefix}/sys/policies/acl/${name}" \
    -H "X-Vault-Token: ${BAO_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$json_body" \
    --max-time 30)
  
  local http_code
  http_code=$(echo "$response" | grep -oP 'HTTP_CODE:\K\d+')
  if [[ "$http_code" -ne 204 ]]; then
    echo "  error: HTTP $http_code"
    echo "$response" | grep -v 'HTTP_CODE:' | tail -n 1
    exit 1
  fi
}

# PUT auth role to specified namespace path
# Args: namespace_path auth_mount role_name role_json
put_auth_role() {
  put_auth_role_ns "$1" "$2" "$3" "$4" "${BAO_TOKEN}"
}

# PUT auth role with explicit namespace and token
# Args: namespace auth_mount role_name role_json token
put_auth_role_ns() {
  local ns="$1"
  local auth_mount="$2"
  local role_name="$3"
  local role_json="$4"
  local token="$5"
  
  echo "  writing $auth_mount role $role_name to namespace $ns"
  local response
  response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
    "${BAO_ADDR}/v1/auth/${auth_mount}/role/${role_name}" \
    -H "X-Vault-Namespace: ${ns}" \
    -H "X-Vault-Token: ${token}" \
    -H "Content-Type: application/json" \
    -d "$role_json" \
    --max-time 30)
  
  local http_code
  http_code=$(echo "$response" | grep -oP 'HTTP_CODE:\K\d+')
  if [[ "$http_code" -ne 204 ]]; then
    echo "  error: HTTP $http_code"
    echo "$response" | grep -v 'HTTP_CODE:' | tail -n 1
    exit 1
  fi
}

# PUT policy with explicit namespace and token
# Args: namespace policy_name policy_file token
put_policy_ns() {
  local ns="$1"
  local name="$2"
  local policy_file="$3"
  local token="$4"
  
  echo "  writing policy $name to namespace $ns"
  
  local json_body
  json_body=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    content = f.read()
print(json.dumps({'policy': content}))
" "$policy_file")
  
  local response
  response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
    "${BAO_ADDR}/v1/sys/policies/acl/${name}" \
    -H "X-Vault-Namespace: ${ns}" \
    -H "X-Vault-Token: ${token}" \
    -H "Content-Type: application/json" \
    -d "$json_body" \
    --max-time 30)
  
  local http_code
  http_code=$(echo "$response" | grep -oP 'HTTP_CODE:\K\d+')
  if [[ "$http_code" -ne 204 ]]; then
    echo "  error: HTTP $http_code"
    echo "$response" | grep -v 'HTTP_CODE:' | tail -n 1
    exit 1
  fi
}

# Write root namespace policies
write_policies() {
  echo "==> policies (root)"
  local policies_found=0
  for policy in "$ROOT/policies/"*.hcl; do
    [[ -f "$policy" ]] || continue
    policies_found=1
    name="$(basename "$policy" .hcl)"
    put_policy "" "$name" "$policy"
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
    role_json=$(subst_client_id "$role_file" "$AUTHENTIK_CLIENT_ID")
    put_auth_role "" "oidc" "$role" "$role_json"
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
  export ROOT
  export GITHUB_JWT_AUDIENCE="${GITHUB_JWT_AUDIENCE:-${BAO_OIDC_AUDIENCE:-https://github.com/GoodMannersHosting}}"
  local role_json
  role_json=$(python3 - <<'PY'
import json, os, pathlib
root = pathlib.Path(os.environ["ROOT"])
aud = os.environ["GITHUB_JWT_AUDIENCE"]
doc = json.loads((root / "jwt/github-actions-ci.json").read_text())
doc["bound_audiences"] = [aud]
if "bound_claims" in doc:
    doc["bound_claims_type"] = "string"
if "bound_subject" in doc:
    del doc["bound_subject"]
print(json.dumps(doc))
PY
)
  put_auth_role "" "$BAO_AUTH_MOUNT" "$role" "$role_json"
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
  put_auth_role "" "$mount" "$role" "$role_json"
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
  
  # Authenticate in this namespace to get namespace-scoped token
  local ns_token
  ns_token=$(auth_namespace "$ns") || exit 1
  
  local policies_found=0
  for policy in "$ns_dir/policies/"*.hcl; do
    [[ -f "$policy" ]] || continue
    policies_found=1
    name="$(basename "$policy" .hcl)"
    put_policy_ns "$ns" "$name" "$policy" "$ns_token"
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
  
  # Authenticate in this namespace to get namespace-scoped token
  local ns_token
  ns_token=$(auth_namespace "$ns") || exit 1
  
  local roles_found=0
  for role_file in "$ns_dir/roles/"*.json; do
    [[ -f "$role_file" ]] || continue
    roles_found=1
    role="$(basename "$role_file" .json)"
    local role_json
    role_json=$(subst_client_id "$role_file" "$AUTHENTIK_CLIENT_ID")
    put_auth_role_ns "$ns" "oidc" "$role" "$role_json" "$ns_token"
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
  command -v curl >/dev/null 2>&1 || die "missing curl"
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
