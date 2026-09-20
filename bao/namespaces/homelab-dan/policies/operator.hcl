# Operator policy for homelab-dan namespace: read/write secrets, no deletion.

# KV v2: create and update secret versions; no soft-delete or destroy
path "secret/data/dan/*" {
  capabilities = ["create", "read", "update", "list"]
}

# Metadata: read and list only (no delete of secret trees)
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
