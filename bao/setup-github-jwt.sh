#!/usr/bin/env bash
# Bootstrap GitHub Actions OIDC on OpenBao (JWT auth mount + OIDC discovery; needs root BAO_TOKEN).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$ROOT/github-jwt.env.example}"

die() { echo "error: $*" >&2; exit 1; }

load_config() {
  [[ -f "$CONFIG" ]] && source "$CONFIG"
  export BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
  export BAO_AUTH_MOUNT="${BAO_AUTH_MOUNT:-${GITHUB_JWT_MOUNT:-jwt}}"
  export GITHUB_JWT_MOUNT="${GITHUB_JWT_MOUNT:-${BAO_AUTH_MOUNT}}"
  export GITHUB_OIDC_ISSUER="${GITHUB_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
  export BAO_OIDC_AUDIENCE="${BAO_OIDC_AUDIENCE:-https://github.com/GoodMannersHosting}"
  export GITHUB_JWT_AUDIENCE="${GITHUB_JWT_AUDIENCE:-${BAO_OIDC_AUDIENCE}}"
  export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-GoodMannersHosting/aws-security-cluster}"
  export GITHUB_REF="${GITHUB_REF:-refs/heads/main}"
  export BAO_CI_ROLE="${BAO_CI_ROLE:-github-actions-ci}"
  export BAO_AWS_INFRA_ROLE="${BAO_AWS_INFRA_ROLE:-github-actions-aws-infra}"
  [[ -n "${BAO_TOKEN:-}" ]] || die "export BAO_TOKEN (root) before running"
}

enable_jwt() {
  if bao auth list -format=json | grep -q "\"${BAO_AUTH_MOUNT}/\""; then
    echo "==> jwt mount ${BAO_AUTH_MOUNT}/ already enabled"
    return
  fi
  echo "==> enabling jwt auth at ${BAO_AUTH_MOUNT}/"
  bao auth enable -path="${BAO_AUTH_MOUNT}" jwt
}

write_jwt_config() {
  echo "==> jwt config (${GITHUB_OIDC_ISSUER})"
  bao write "auth/${BAO_AUTH_MOUNT}/config" \
    oidc_discovery_url="${GITHUB_OIDC_ISSUER}" \
    bound_issuer="${GITHUB_OIDC_ISSUER}"
}

write_ci_policy() {
  echo "==> policy ci-sync"
  bao policy write ci-sync "${ROOT}/policies/ci-sync.hcl"
}

render_ci_role() {
  python3 - <<'PY'
import json, os, pathlib
root = pathlib.Path(os.environ["ROOT"])
repo = os.environ["GITHUB_REPOSITORY"]
ref = os.environ["GITHUB_REF"]
aud = os.environ["GITHUB_JWT_AUDIENCE"]
doc = json.loads((root / "jwt/github-actions-ci.json").read_text())
doc["bound_audiences"] = [aud]
doc["bound_subject"] = f"repo:{repo}:ref:{ref}"
doc["bound_claims"] = {"repository": repo, "ref": ref}
json.dump(doc, __import__("sys").stdout)
PY
}

write_ci_role() {
  echo "==> jwt role ${BAO_CI_ROLE}"
  export ROOT
  render_ci_role | bao write "auth/${BAO_AUTH_MOUNT}/role/${BAO_CI_ROLE}" -
}

write_aws_infra_policy() {
  echo "==> policy ci-aws-infra"
  bao policy write ci-aws-infra "${ROOT}/policies/ci-aws-infra.hcl"
}

render_aws_infra_role() {
  python3 - <<'PY'
import json, os, pathlib
root = pathlib.Path(os.environ["ROOT"])
repo = os.environ["GITHUB_REPOSITORY"]
ref = os.environ["GITHUB_REF"]
aud = os.environ["GITHUB_JWT_AUDIENCE"]
doc = json.loads((root / "jwt/github-actions-aws-infra.json").read_text())
doc["bound_audiences"] = [aud]
doc["bound_subject"] = f"repo:{repo}:ref:{ref}"
doc["bound_claims"] = {"repository": repo, "ref": ref}
json.dump(doc, __import__("sys").stdout)
PY
}

write_aws_infra_role() {
  echo "==> jwt role ${BAO_AWS_INFRA_ROLE}"
  export ROOT
  render_aws_infra_role | bao write "auth/${BAO_AUTH_MOUNT}/role/${BAO_AWS_INFRA_ROLE}" -
}

main() {
  command -v bao >/dev/null 2>&1 || die "missing bao CLI"
  command -v python3 >/dev/null 2>&1 || die "missing python3"
  load_config
  enable_jwt
  write_jwt_config
  write_ci_policy
  write_ci_role
  write_aws_infra_policy
  write_aws_infra_role
  echo "done. mount=${BAO_AUTH_MOUNT} audience=${BAO_OIDC_AUDIENCE} roles=${BAO_CI_ROLE},${BAO_AWS_INFRA_ROLE}"
}

main "$@"
