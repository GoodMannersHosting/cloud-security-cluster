# GitHub Actions aws-infra: read Authentik API + IC SCIM tokens for Pulumi.
path "secret/data/pulumi/authentik" {
  capabilities = ["read"]
}

path "secret/metadata/pulumi/authentik" {
  capabilities = ["read"]
}
