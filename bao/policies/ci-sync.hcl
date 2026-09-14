# GitHub Actions CI: sync policies and auth roles from git (no secret data access).
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
