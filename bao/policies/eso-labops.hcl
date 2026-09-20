# ESO (home-enterprise-labops, ClusterSecretStore): read-only access to all labops secrets.
path "secret/data/labops/*" {
  capabilities = ["read"]
}
path "secret/metadata/labops/*" {
  capabilities = ["read"]
}
