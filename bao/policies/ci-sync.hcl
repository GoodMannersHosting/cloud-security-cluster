# GitHub Actions CI: sync policies, auth methods, and roles from git.
# Explicitly has NO access to secret data — deny is listed last and wins.

# ── Root namespace ─────────────────────────────────────────────────────────────

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Auth backend lifecycle (enable / disable / tune).
# sys/auth/* is root-protected in OpenBao and requires sudo.
path "sys/auth/+" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

# Mount lifecycle for auth and secret engines (root namespace).
# sys/mounts/{type}/{path} is used for enable/disable/tune/read.
path "sys/mounts/*" {
  capabilities = ["read", "list"]
}

path "sys/mounts/*/tune" {
  capabilities = ["create", "read", "update"]
}

path "auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/+/config" {
  capabilities = ["create", "read", "update"]
}

path "auth" {
  capabilities = ["read"]
}

# ── Child namespaces ───────────────────────────────────────────────────────────
# In OpenBao, cross-namespace paths from root are prefixed with the namespace
# name directly (e.g. "homelab-dan/sys/...").
# The "+" glob matches any single namespace segment.

path "+/sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "+/sys/auth/+" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "+/sys/mounts/*" {
  capabilities = ["read", "list"]
}

path "+/sys/mounts/*/tune" {
  capabilities = ["create", "read", "update"]
}

path "+/auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "+/auth/+/config" {
  capabilities = ["create", "read", "update"]
}

path "+/auth" {
  capabilities = ["read"]
}

# ── Explicit deny: no secret data access ──────────────────────────────────────
# Defense-in-depth: CI must never read or write secret values.

path "secret/*" {
  capabilities = ["deny"]
}

path "+/secret/*" {
  capabilities = ["deny"]
}
