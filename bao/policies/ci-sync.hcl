# GitHub Actions CI: sync policies and auth roles from git (no secret data access).

# Root namespace
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/+/config" {
  capabilities = ["read"]
}

path "identity/group/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "identity/group-alias/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "identity/group/name/*" {
  capabilities = ["read"]
}

path "auth" {
  capabilities = ["read"]
}

# Namespace-specific policy sync (all namespaces)
path "namespace/*/sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "namespace/*/auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "namespace/*/auth/+/config" {
  capabilities = ["read"]
}

# Namespace-specific policy sync (all namespaces)
path "namespace/*/sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "namespace/*/auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "namespace/*/auth/+/config" {
  capabilities = ["read"]
}

path "namespace/*/identity/group/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "namespace/*/identity/group-alias/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "namespace/*/identity/group/name/*" {
  capabilities = ["read"]
}

path "namespace/*/auth" {
  capabilities = ["read"]
}

# Namespace-specific policy sync (all namespaces)
# OpenBao uses sys/namespace/<ns>/ prefix for namespace operations
path "sys/namespace/*/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/namespace/*/auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/namespace/*/auth/+/config" {
  capabilities = ["read"]
}

path "sys/namespace/*/identity/group/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/namespace/*/identity/group-alias/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/namespace/*/identity/group/name/*" {
  capabilities = ["read"]
}

path "sys/namespace/*/auth" {
  capabilities = ["read"]
}
