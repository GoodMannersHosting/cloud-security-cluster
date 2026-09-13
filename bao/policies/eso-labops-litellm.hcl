# ESO (home-enterprise-labops, aiml namespace): read-only litellm master key.
path "secret/data/labops/aiml/litellm-master-key" {
  capabilities = ["read"]
}
path "secret/metadata/labops/aiml/litellm-master-key" {
  capabilities = ["read"]
}
