# OpenBao on Docker (Hetzner)

1. Ensure `postgres` and `traefik` stacks are running and networks `data` and `traefik` exist.
2. Copy `local.hcl.example` to `${OPENBAO_CONFIG_PATH}/local.hcl` and set `connection_url`, `api_addr`, and `cluster_addr` to your domain and database password.
3. `docker compose up -d`
4. Run `bao operator init` and unseal (shamir), or complete KMS migration using `local-kms.hcl.example` and AWS documentation.

Run the Roles Anywhere credential helper in a sidecar sharing the OpenBao network namespace if you use `AWS_EC2_METADATA_SERVICE_ENDPOINT` on loopback.

## Installing external secrets engine plugins (e.g. AWS)

Since ~1.16, secrets engines like `aws` ship as external plugins rather than
being built into the OpenBao binary — they must be downloaded and registered
before they can be mounted. Binaries come from
[openbao/openbao-plugins releases](https://github.com/openbao/openbao-plugins/releases).

On the host (`${OPENBAO_PLUGINS_DIR:-/opt/stacks/openbao/plugins}`):

```bash
mkdir -p /opt/stacks/openbao/plugins && cd /opt/stacks/openbao/plugins
VERSION=secrets-aws-v0.3.1
curl -sLO "https://github.com/openbao/openbao-plugins/releases/download/${VERSION}/openbao-plugin-secrets-aws_linux_amd64_v1.tar.gz"
curl -sLO "https://github.com/openbao/openbao-plugins/releases/download/${VERSION}/checksums-secrets-aws.txt"
tar -xzf openbao-plugin-secrets-aws_linux_amd64_v1.tar.gz openbao-plugin-secrets-aws_linux_amd64_v1
mv openbao-plugin-secrets-aws_linux_amd64_v1 openbao-plugin-secrets-aws
chmod +x openbao-plugin-secrets-aws
grep '  openbao-plugin-secrets-aws_linux_amd64_v1$' checksums-secrets-aws.txt  # note the sha256
```

`docker compose up -d` (picks up the new `/openbao/plugins` mount and
`plugin_directory` config), then register it in the catalog under the name
`aws` (the `-command` flag points at the actual binary; the catalog *name*
is what `infra/openbao/index.ts`'s `vault.aws.SecretBackend` mounts):

```bash
bao plugin register -sha256=<sha256 from above> -command=openbao-plugin-secrets-aws secret aws
```

Once registered, the existing `vault.aws.SecretBackend` resource mounts and
configures it on the next `pulumi up` — no `bao secrets enable` or Pulumi
changes needed for the plugin install itself.
