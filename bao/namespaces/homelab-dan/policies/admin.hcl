# Admin policy for homelab-dan namespace: full control over namespace secrets and auth.

# KV v2: full access including permanent deletion
path "secret/data/dan/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/dan/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/delete/dan/*" {
  capabilities = ["update"]
}

path "secret/undelete/dan/*" {
  capabilities = ["update"]
}

path "secret/destroy/dan/*" {
  capabilities = ["update"]
}

# List top-level KV keys
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
