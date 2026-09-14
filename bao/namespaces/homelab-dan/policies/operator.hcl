# Operator policy for homelab-dan namespace: read/write secrets
path "secret/dan/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "sys/*" {
  capabilities = ["read", "list"]
}