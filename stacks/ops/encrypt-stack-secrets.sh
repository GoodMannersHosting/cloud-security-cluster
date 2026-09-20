#!/usr/bin/env bash
# Encrypt /opt/stacks/<stack>/.env into stacks/<stack>/secrets.enc.env for GitOps.
# Run on keeper (or anywhere with plaintext .env + age public key).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/hcloud-security-cluster}"
STACKS="${STACKS:-/opt/stacks}"
SOPS_CONFIG="${SOPS_CONFIG:-${REPO_ROOT}/.sops.yaml}"

log() { printf '==> %s\n' "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }

need_cmd sops
[[ -f "${SOPS_CONFIG}" ]] || {
  echo "missing ${SOPS_CONFIG} (copy from .sops.yaml.example)" >&2
  exit 1
}

encrypt_stack() {
  local stack="$1"
  local plain="${STACKS}/${stack}/.env"
  local out="${REPO_ROOT}/stacks/${stack}/secrets.enc.env"
  [[ -f "${plain}" ]] || { log "skip ${stack} (no ${plain})"; return 0; }
  local tmp
  tmp="$(mktemp)"
  grep -Ev '^[[:space:]]*(#|$)' "${plain}" >"${tmp}" || true
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    log "skip ${stack} (empty ${plain})"
    return 0
  fi
  install -d -m 0755 "$(dirname "${out}")"
  local rel="stacks/${stack}/secrets.enc.env"
  SOPS_CONFIG="${SOPS_CONFIG}" sops --config "${SOPS_CONFIG}" encrypt \
    --filename-override "${rel}" \
    --input-type dotenv --output-type dotenv \
    "${tmp}" >"${out}"
  rm -f "${tmp}"
  chmod 644 "${out}"
  log "encrypted ${plain} -> ${out}"
}

for stack in traefik authentik openbao powerdns dnsweaver alloy doco-cd; do
  encrypt_stack "${stack}"
done

log "Commit stacks/*/secrets.enc.env and push to main for GitOps deploy"
