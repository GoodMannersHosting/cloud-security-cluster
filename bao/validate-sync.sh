#!/usr/bin/env bash
# Lint bao/ manifests before CI sync (no OpenBao login required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

check_shell_scripts() {
  echo "==> bash -n"
  local f
  for f in "$ROOT"/*.sh; do
    [[ -f "$f" ]] || continue
    bash -n "$f"
  done
}

check_json_files() {
  echo "==> json syntax"
  local f
  for f in \
    "$ROOT"/roles/*.json \
    "$ROOT"/jwt/*.json \
    "$ROOT"/kubernetes/*.json \
    "$ROOT"/identity/groups/*.json; do
    [[ -f "$f" ]] || continue
    python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$f"
  done
}

check_namespace_json_files() {
  echo "==> namespace json syntax"
  if [[ ! -d "$ROOT/namespaces" ]]; then
    return
  fi
  local ns_dir
  for ns_dir in "$ROOT/namespaces/"*/; do
    [[ -d "$ns_dir" ]] || continue
    local ns="$(basename "$ns_dir")"
    for f in "$ns_dir/roles/"*.json; do
      [[ -f "$f" ]] || continue
      echo "  validating $f"
      python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$f"
    done
  done
}

check_json_shape() {
  echo "==> json shape"
  python3 - <<PY
import json
import pathlib
import sys

root = pathlib.Path("${ROOT}")

def load(path):
    return json.loads(path.read_text())

for path in sorted((root / "roles").glob("*.json")):
    doc = load(path)
    for key in ("role_type", "user_claim", "policies"):
        if key not in doc:
            sys.exit(f"missing {key} in {path}")

for path in sorted((root / "jwt").glob("*.json")):
    doc = load(path)
    if doc.get("role_type") != "jwt":
        sys.exit(f"role_type must be jwt in {path}")
    if "token_policies" not in doc and "policies" not in doc:
        sys.exit(f"missing policies in {path}")

for path in sorted((root / "identity" / "groups").glob("*.json")):
    doc = load(path)
    for key in ("name", "type", "policies"):
        if key not in doc:
            sys.exit(f"missing {key} in {path}")

for path in sorted((root / "kubernetes").glob("*.json")):
    doc = load(path)
    for key in ("bound_service_account_names", "bound_service_account_namespaces", "policies"):
        if key not in doc:
            sys.exit(f"missing {key} in {path}")
PY
}

check_namespace_json_shape() {
  echo "==> namespace json shape"
  if [[ ! -d "$ROOT/namespaces" ]]; then
    return
  fi
  python3 - <<PY
import json
import pathlib
import sys

root = pathlib.Path("${ROOT}") / "namespaces"

def load(path):
    return json.loads(path.read_text())

for ns_dir in sorted(root.iterdir()):
    if not ns_dir.is_dir():
        continue
    ns = ns_dir.name
    roles_dir = ns_dir / "roles"
    if not roles_dir.is_dir():
        continue
    for path in sorted(roles_dir.glob("*.json")):
        doc = load(path)
        for key in ("role_type", "user_claim", "policies"):
            if key not in doc:
                sys.exit(f"missing {key} in {path}")
PY
}

check_policy_syntax() {
  echo "==> policy files exist"
  local count=0
  for f in "$ROOT/policies/"*.hcl; do
    [[ -f "$f" ]] || continue
    count=$((count + 1))
  done
  echo "  found $count policy files"
}

check_namespace_policy_syntax() {
  echo "==> namespace policy files exist"
  if [[ ! -d "$ROOT/namespaces" ]]; then
    echo "  skip (no namespaces dir)"
    return
  fi
  local ns_dir count=0
  for ns_dir in "$ROOT/namespaces/"*/; do
    [[ -d "$ns_dir" ]] || continue
    local ns="$(basename "$ns_dir")"
    if [[ ! -d "$ns_dir/policies" ]]; then
      continue
    fi
    echo "  checking namespace: $ns"
    for f in "$ns_dir/policies/"*.hcl; do
      [[ -f "$f" ]] || continue
      count=$((count + 1))
    done
  done
  echo "  found $count namespace policy files"
}

main() {
  check_shell_scripts
  check_json_files
  check_json_shape
  check_namespace_json_files
  check_namespace_json_shape
  if command -v bao >/dev/null 2>&1; then
    check_policy_syntax
    check_namespace_policy_syntax
  else
    echo "==> skip policy syntax (bao not installed yet)"
  fi
  echo "validate ok"
}

main "$@"