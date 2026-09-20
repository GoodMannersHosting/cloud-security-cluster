#!/usr/bin/env bash
# Bootstrap Kubernetes auth on OpenBao for home-enterprise-labops' ESO
# (Kubernetes auth mount + config + policy + role; needs root BAO_TOKEN and
# kubectl pointed at the home-enterprise-labops cluster).
#
# Prerequisite: kubernetes/core/kube-system/openbao-auth/ synced in that cluster, so the
# token-reviewer ServiceAccount and its token Secret exist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

load_config() {
  export BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
  export BAO_K8S_MOUNT="${BAO_K8S_MOUNT:-kubernetes-labops}"
  export BAO_K8S_ROLE="${BAO_K8S_ROLE:-eso-litellm}"
  [[ -n "${BAO_TOKEN:-}" ]] || die "export BAO_TOKEN (root) before running"
}

enable_kubernetes_auth() {
  if bao auth list -format=json | grep -q "\"${BAO_K8S_MOUNT}/\""; then
    echo "==> kubernetes auth mount ${BAO_K8S_MOUNT}/ already enabled"
    return
  fi
  echo "==> enabling kubernetes auth at ${BAO_K8S_MOUNT}/"
  bao auth enable -path="${BAO_K8S_MOUNT}" kubernetes
}

write_kubernetes_config() {
  echo "==> kubernetes auth config (${BAO_K8S_MOUNT})"
  local host ca_cert reviewer_jwt
  host="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
  ca_cert="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)"
  reviewer_jwt="$(kubectl get secret token-reviewer-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)"
  [[ -n "$host" ]] || die "could not read kubernetes_host from current kubectl context"
  [[ -n "$reviewer_jwt" ]] || die "could not read token-reviewer-token secret (is kubernetes/core/kube-system/openbao-auth/ synced?)"
  bao write "auth/${BAO_K8S_MOUNT}/config" \
    kubernetes_host="${host}" \
    kubernetes_ca_cert="${ca_cert}" \
    token_reviewer_jwt="${reviewer_jwt}"
}

write_policy() {
  echo "==> policy eso-labops"
  bao policy write eso-labops "${ROOT}/policies/eso-labops.hcl"
}

write_role() {
  echo "==> kubernetes role ${BAO_K8S_ROLE}"
  bao write "auth/${BAO_K8S_MOUNT}/role/${BAO_K8S_ROLE}" @"${ROOT}/kubernetes/labops-eso.json"
}

main() {
  command -v bao >/dev/null 2>&1 || die "missing bao CLI"
  command -v kubectl >/dev/null 2>&1 || die "missing kubectl (pointed at home-enterprise-labops)"
  load_config
  enable_kubernetes_auth
  write_kubernetes_config
  write_policy
  write_role
  echo "done. mount=${BAO_K8S_MOUNT} role=${BAO_K8S_ROLE}"
}

main "$@"
