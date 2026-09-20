# Reader: browse available engines; read secret values. No writes.
# Used by OIDC role "reader" (Authentik group: keeper-reader).

# List available secret engines and auth methods (no raw sys data)
path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

# KV v2: read values and list keys (no write, no delete)
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
