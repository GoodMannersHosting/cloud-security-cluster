# Operator policy for homelab-dan namespace: read/write secrets, no deletion.
# Paths are namespace-relative; no cross-namespace access.

# KV v2: create and update secret versions; no soft-delete or destroy
path "secret/data/*" {
  capabilities = ["create", "read", "update", "list"]
}

# Metadata: read and list only (no delete of secret trees)
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
