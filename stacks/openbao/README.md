# OpenBao on Docker (Hetzner)

1. Ensure `postgres` and `traefik` stacks are running and networks `data` and `traefik` exist.
2. Copy `local.hcl.example` to `${OPENBAO_CONFIG_PATH}/local.hcl` and set `connection_url`, `api_addr`, and `cluster_addr` to your domain and database password.
3. `docker compose up -d`
4. Run `bao operator init` and unseal (shamir), or complete KMS migration using `local-kms.hcl.example` and AWS documentation.

Run the Roles Anywhere credential helper in a sidecar sharing the OpenBao network namespace if you use `AWS_EC2_METADATA_SERVICE_ENDPOINT` on loopback.

## Installing external secrets engine plugins (e.g. AWS)

Since ~1.16, secrets engines like `aws` ship as external plugins rather than
being built into the OpenBao binary. OpenBao 2.6+ supports declaring these
directly in server config — it pulls the OCI image, verifies the checksum,
and extracts the binary into `plugin_directory` itself on startup, no manual
download or `bao plugin register` needed. See `config/openbao.hcl.example`:

```hcl
plugin "secret" "aws" {
  image       = "ghcr.io/openbao/openbao-plugin-secrets-aws"
  version     = "v0.3.1"
  binary_name = "openbao-plugin-secrets-aws"
  sha256sum   = "641ae1858c0f660b4c3761286d627e1dcfd33dc35e7c83eb81ca9050b5bdc6d8"
}
```

The block's name (`"aws"`) is the catalog name that `vault.aws.SecretBackend`
in `infra/openbao/index.ts` mounts — nothing else to configure there. Just
add the block to your real `/opt/stacks/openbao/config/openbao.hcl` and
`docker compose up -d`; `${OPENBAO_PLUGINS_DIR:-./plugins}` must be writable
(not `:ro`) since OpenBao writes the downloaded binary there.

To bump the version later, update `version` and `sha256sum` together —
pull the new tag's `checksums-secrets-aws.txt` from
[openbao/openbao-plugins releases](https://github.com/openbao/openbao-plugins/releases)
for the `linux_amd64` entry (matches the OCI image's linux/amd64 layer).
