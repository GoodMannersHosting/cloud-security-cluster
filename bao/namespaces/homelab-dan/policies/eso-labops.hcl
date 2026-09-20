# ESO ClusterSecretStore: read-only access to dan secrets.
path "secret/data/dan/*" {
  capabilities = ["read"]
}
path "secret/metadata/dan/*" {
  capabilities = ["read"]
}
