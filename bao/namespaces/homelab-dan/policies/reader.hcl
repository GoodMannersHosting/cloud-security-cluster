# Reader policy for homelab-dan namespace: read-only access to secrets.

# KV v2: read values only
path "secret/data/dan/*" {
  capabilities = ["read"]
}

# Metadata: read and list to browse available keys
path "secret/metadata/dan/*" {
  capabilities = ["read", "list"]
}

# List top-level KV keys
path "secret/" {
  capabilities = ["list"]
}

# View available secret engines
path "sys/mounts" {
  capabilities = ["read"]
}
