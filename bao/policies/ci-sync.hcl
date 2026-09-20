# GitHub Actions CI: sync policies, auth methods, and roles from git.
# No access to secret data.

# ── Root namespace ─────────────────────────────────────────────────────────────

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Auth backend lifecycle (enable / disable / tune).
# sys/auth/* is root-protected in OpenBao and requires sudo.
path "sys/auth/+" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/mounts/auth/+" {
  capabilities = ["read"]
}

path "sys/mounts/auth/+/tune" {
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

path "+/sys/mounts/auth/+" {
  capabilities = ["read"]
}

path "+/sys/mounts/auth/+/tune" {
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
