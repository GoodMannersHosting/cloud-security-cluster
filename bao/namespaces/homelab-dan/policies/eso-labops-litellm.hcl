# ESO: read-only access to litellm master key.
path "secret/data/dan/aiml/litellm-master-key" {
  capabilities = ["read"]
}
path "secret/metadata/dan/aiml/litellm-master-key" {
  capabilities = ["read"]
}
