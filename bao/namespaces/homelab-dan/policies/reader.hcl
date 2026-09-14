# Reader policy for homelab-dan namespace: read-only access
path "secret/dan/*" {
  capabilities = ["read", "list"]
}
path "sys/*" {
  capabilities = ["read", "list"]
}