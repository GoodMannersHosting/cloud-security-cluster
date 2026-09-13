#!/usr/bin/env bash
# Apply policies and auth roles from this directory (CI or local with BAO_TOKEN).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAO_AUTH_MOUNT="${BAO_AUTH_MOUNT:-${GITHUB_JWT_MOUNT:-jwt}}"

die() { echo "error: $*" >&2; exit 1; }

require_token() {
  export BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN:-}}"
  [[ -n "${BAO_TOKEN}" ]] || die "BAO_TOKEN or VAULT_TOKEN required"
  export BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
}

subst_client_id() {
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1]))
doc['bound_audiences'] = [sys.argv[2]]
json.dump(doc, sys.stdout)
" "$1" "$2"
}

write_policies() {
  echo "==> policies"
  for policy in "$ROOT/policies/"*.hcl; do
    name="$(basename "$policy" .hcl)"
    bao policy write "$name" "$policy"
  done
}

write_oidc_roles() {
  [[ -n "${AUTHENTIK_CLIENT_ID:-}" ]] || {
    echo "==> skip oidc roles (AUTHENTIK_CLIENT_ID unset)"
    return
  }
  echo "==> oidc roles"
  for role in admin reader operator; do
    subst_client_id "$ROOT/roles/${role}.json" "$AUTHENTIK_CLIENT_ID" \
      | bao write "auth/oidc/role/${role}" -
  done
}

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

write_kubernetes_role() {
  if [[ ! -f "$ROOT/kubernetes/labops-eso-litellm.json" ]]; then
    return
  fi
  local mount="${BAO_K8S_MOUNT:-kubernetes-labops}"
  local role="${BAO_K8S_ROLE:-eso-litellm}"
  echo "==> kubernetes role ${role}"
  # ci-sync can't list auth mounts to check first (no sys/auth capability), so
  # this fails soft: until bao/setup-kubernetes-auth.sh has been run once to
  # enable the mount, this write 404s and other syncs shouldn't be blocked on it.
  if ! bao write "auth/${mount}/role/${role}" @"$ROOT/kubernetes/labops-eso-litellm.json"; then
    echo "warn: could not write auth/${mount}/role/${role} (mount not enabled yet? run bao/setup-kubernetes-auth.sh)" >&2
  fi
}

main() {
  command -v bao >/dev/null 2>&1 || die "missing bao CLI"
  require_token
  write_policies
  write_oidc_roles
  write_jwt_ci_role
  write_kubernetes_role
  echo "done"
}

main "$@"
