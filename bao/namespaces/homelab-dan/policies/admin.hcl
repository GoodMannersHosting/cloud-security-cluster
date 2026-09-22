# Admin policy for homelab-dan namespace: full control over all secrets and auth.
# Paths are namespace-relative; no cross-namespace access.

# KV v2: full access including permanent deletion
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/delete/*" {
  capabilities = ["update"]
}

path "secret/undelete/*" {
  capabilities = ["update"]
}

path "secret/destroy/*" {
  capabilities = ["update"]
}

path "secret/" {
  capabilities = ["list"]
}

# Full auth method management within namespace
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Namespace system info (read/list only — no sudo, no mount management)
path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/policies/acl/*" {
  capabilities = ["read", "list"]
}
