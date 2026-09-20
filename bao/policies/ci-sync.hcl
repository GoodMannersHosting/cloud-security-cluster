# GitHub Actions CI: sync policies and auth roles from git.
# No access to secret data.

# Root namespace policies and auth roles
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/+/config" {
  capabilities = ["read"]
}

path "auth" {
  capabilities = ["read"]
}

# Child namespace policies and auth roles.
# In OpenBao, cross-namespace paths from root are prefixed with the namespace
# name directly (e.g. "homelab-dan/sys/..."), not "namespace/homelab-dan/sys/...".
# The "+" glob matches any single namespace segment.
path "+/sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "+/auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "+/auth/+/config" {
  capabilities = ["read"]
}

path "+/auth" {
  capabilities = ["read"]
}
