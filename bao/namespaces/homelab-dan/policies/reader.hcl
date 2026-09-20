# Reader policy for homelab-dan namespace: read-only access to all secrets.
# Paths are namespace-relative; no cross-namespace access.

# KV v2: read values only
path "secret/data/*" {
  capabilities = ["read"]
}

# Metadata: read and list to browse available keys
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

path "secret/" {
  capabilities = ["list"]
}

# View available secret engines
path "sys/mounts" {
  capabilities = ["read"]
}
