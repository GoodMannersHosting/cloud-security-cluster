Single-node Compose for Traefik, Authentik, and OpenBao on **keeper.goodmanners.services**.

Stack **compose and secrets** come from git. Doco-CD clones this repo on push to `main` and applies **`.doco-cd.yml`**. Host paths under **`/opt/stacks/`** hold bind-mount data only (ACME, OpenBao config/KMS creds, age key).

## Production layout

| Path | Purpose |
|------|---------|
| `stacks/*/secrets.enc.env` (git) | SOPS-encrypted stack env (Doco-CD decrypts at deploy) |
| `/opt/stacks/doco-cd/sops_age_key.txt` | age **secret** key for SOPS (never commit) |
| `/opt/stacks/traefik/` | ACME (`acme.json`), dynamic middlewares (from git sync) |
| `/opt/stacks/openbao/` | `config/`, `aws/` (KMS seal credentials) |
| `/opt/hcloud-security-cluster/` | Host ops clone (scripts, manual runs) |
| `/opt/stack-secrets/` | age key backup, optional `bao-admin.token` for automation |
| `/opt/backups/keeper/` | Local backup staging; nightly S3 upload via Roles Anywhere |
| `/mnt/sec-hil-1-authentik/` | Authentik Postgres + app data |
| `/mnt/data/openbao/` | OpenBao data volume |

Install or refresh GitOps on the VPS:

```bash
sudo bash /opt/hcloud-security-cluster/stacks/doco-cd/install-prod.sh
```

## Prerequisites

- Docker Engine and Docker Compose v2
- DNS A/AAAA for `auth`, `keeper`, `pdns`, `poweradmin`, `traefik`, and `doco-cd` hostnames
- External `traefik` Docker network (created by the traefik stack on first boot)
- **`age`** and **`sops`** on the host for encrypting secrets into git

```bash
sudo mkdir -p /mnt/data/postgres/openbao /mnt/data/openbao /mnt/data/postgres/powerdns /mnt/data/poweradmin/config /var/log/traefik /opt/stacks/dnsweaver/aws
sudo chown -R 70:70 /mnt/data/postgres/powerdns
sudo chown -R 82:82 /mnt/data/poweradmin
sudo touch /var/log/traefik/access.log
```

## Deploy order

Doco-CD applies stacks in this order (see `.doco-cd.yml`):

1. **traefik** — ingress, ACME resolver `letsencrypt`
2. **authentik** — Postgres, server, worker (via socket-proxy), embedded outpost routes
3. **openbao** — Postgres, AWS KMS auto-unseal
4. **powerdns** — authoritative DNS server + PostgreSQL backend + Poweradmin UI (DNS TCP/UDP 53 and API/UI routed via Traefik)

Poweradmin stores its own users/settings in Postgres database `POWERADMIN_DB` (default `poweradmin`) on the same Postgres service; zone data stays in `POSTGRES_DB` and is managed via the PowerDNS API. Fresh volumes get `poweradmin` from `init-poweradmin-db.sh`. On an existing Postgres volume:

```bash
docker exec -it powerdns-postgresql \
  psql -U "$POSTGRES_USER" -c "CREATE DATABASE poweradmin OWNER $POSTGRES_USER"
```

5. **dnsweaver** — watches Traefik labels and writes matching A records into the Route53 zone via `route53-dnsweaver-webhook`
6. **alloy** — metrics/logs collector (remote_write + Loki push; no local Grafana)

**Doco-CD** is host-managed (`install-prod.sh` / `cold-start-doco-cd.sh`), not a GitOps deploy target in `.doco-cd.yml`.

After Doco-CD is up, use **`stacks/ops/reconcile-gitops.sh`** (or push to `main`). Do not run compose from `/opt/stacks/*/compose.yaml`.

## Secrets (GitOps + SOPS)

1. **In git:** `stacks/{traefik,authentik,openbao,powerdns,dnsweaver,doco-cd,alloy}/secrets.enc.env` encrypted with age (see **`.sops.yaml`**).
2. **On keeper only:** `/opt/stacks/doco-cd/sops_age_key.txt` — Doco-CD mounts this via `compose.sops.yaml` and decrypts env files at deploy time.
3. **Rotate or add a secret:** edit `/opt/stacks/<stack>/.env` on keeper, then:

```bash
sudo /opt/hcloud-security-cluster/stacks/ops/encrypt-stack-secrets.sh
cd /opt/hcloud-security-cluster && git add stacks/*/secrets.enc.env
git commit -m "chore(secrets): rotate stack env" && git push
```

Host `/opt/stacks/*/.env` is used only for cold-start (`compose.install.yaml`) and encrypt input; deploys read **`secrets.enc.env`** from the clone.

Never commit plaintext **`stacks/*/.env`**, **`bao/config.env`**, or **`sops_age_key.txt`**.

## Doco-CD (Compose GitOps)

[Doco-CD](https://github.com/kimdre/doco-cd) runs `docker compose` per stack when GitHub sends a webhook.

1. Run **`stacks/doco-cd/install-prod.sh`** (clone, Doco-CD, SOPS key, ops cron).
2. Set **`GIT_ACCESS_TOKEN`** in encrypted doco-cd secrets if the repo is private.
3. GitHub webhook on **`GoodMannersHosting/aws-security-cluster`**:
   - URL: `https://doco-cd.goodmanners.services/v1/webhook`
   - Secret: **`WEBHOOK_SECRET`** (in `stacks/doco-cd/secrets.enc.env`)
   - Content type: `application/json`
   - Events: **push** on branch **main** only
4. **`MAX_CONCURRENT_DEPLOYMENTS=1`** in doco-cd env (serial deploys).

The UI at `https://doco-cd.goodmanners.services` uses Authentik forward auth. **`/v1/webhook`** and **`/v1/health`** bypass forward auth.

**Doco-CD updates:** apply compose/env changes on the host with **`stacks/doco-cd/install-prod.sh`** or **`stacks/ops/cold-start-doco-cd.sh`** (not via webhook GitOps). Legacy **`bootstrap-doco-self-deploy.sh`** remains for one-off label repair if needed.

For a greenfield VPS with no existing `/opt/stacks`, use **`stacks/doco-cd/bootstrap.sh`**.

## Authentik blueprints

Git-managed blueprints in **`authentik/blueprints/`** mount into the worker at **`/blueprints/custom`**.

| Blueprint | Purpose |
|-----------|---------|
| `010-platform-groups.yaml` | `platform-admin` group + policy |
| `020-keeper-openbao.yaml` | Keeper OIDC app, groups scope |
| `030-doco-cd-forward-auth.yaml` | Doco-CD forward auth provider + outpost |
| `040-brand-goodmanners.yaml` | Brand for auth hostname |
| `050-poweradmin-oidc.yaml` | Poweradmin OIDC app + access groups |

After blueprints apply:

- Add your user to **`platform-admin`** (Doco-CD UI) and **`keeper-admin`** (OpenBao OIDC admin)
- Add DNS admins to **`poweradmin-admin`** (or viewers to **`poweradmin-viewer`**); copy the Poweradmin provider client secret into powerdns secrets
- OpenBao OIDC and policies: repo **`bao/`** (`setup.sh` with `config.env` on the host — not in git)

If blueprint discovery fails:

```bash
sudo bash /opt/hcloud-security-cluster/stacks/ops/fix-blueprints.sh
docker restart authentik-worker
```

**`AUTHENTIK_BLUEPRINTS_PATH`** must point at the git blueprints dir (in encrypted authentik secrets).

## Operations (`stacks/ops/`)

| Script | Purpose |
|--------|---------|
| `verify-gitops.sh` | Clone alignment, encrypted env in clone, compose projects |
| `reconcile-gitops.sh` | Pull host clone, sync traefik binds, webhook or bootstrap |
| `encrypt-stack-secrets.sh` | Host `.env` → `stacks/*/secrets.enc.env` in clone |
| `setup-sops.sh` | age key on host + run encrypt |
| `bootstrap-doco-self-deploy.sh` | One-time / forced Doco-CD GitOps stamp |
| `cold-start-doco-cd.sh` | Start Doco-CD before first GitOps deploy |
| `apply-keeper-post-deploy.sh` | Host hardening + OpenBao file audit + auditd check |
| `harden-host.sh` | Unattended upgrades, permissions, Docker/sysctl/auditd |
| `healthcheck.sh` | Container + HTTPS smoke checks (exit non-zero on failure) |
| `backup.sh` | Postgres dumps + data tarballs; S3 upload when configured |
| `restore.sh` | Restore from local backup dir or S3 stamp |
| `BACKUP-RESTORE.md` | Backup contents, S3 layout, restore procedures |
| `install-cron.sh` | Cron: backup 03:00 UTC, health hourly, gitops verify :15 |
| `fix-blueprints.sh` | Orphan blueprint cleanup |

### Cron (keeper)

Installed by **`install-cron.sh`** → `/etc/cron.d/hcloud-security-cluster`:

| Schedule | Job | Log |
|----------|-----|-----|
| `0 3 * * *` | `backup.sh` | `/var/log/hcloud-backup.log` |
| `0 * * * *` | `healthcheck.sh` | `/var/log/hcloud-health.log` |
| `15 * * * *` | `verify-gitops.sh` | `/var/log/hcloud-gitops.log` |

Run manually after changes:

```bash
sudo /opt/hcloud-security-cluster/stacks/ops/apply-keeper-post-deploy.sh
sudo /opt/hcloud-security-cluster/stacks/ops/healthcheck.sh
sudo /opt/hcloud-security-cluster/stacks/ops/verify-gitops.sh
```

### Hardening and audit

**`apply-keeper-post-deploy.sh`** runs:

- **`harden-host.sh`** — unattended security upgrades, secret file modes, Docker `daemon.json`, sysctl, **Linux auditd** rules on sensitive paths
- **`bao/enable-audit.sh`** — adds **`audit "file"`** stanza to **`/opt/stacks/openbao/config/openbao.hcl`** and restarts OpenBao (no root token; OpenBao >= 2.3.2 blocks API audit enable)

### Off-site backups

Postgres dumps upload via **IAM Roles Anywhere** (see **`backup.env`** on keeper, **`backup.env.example`**). AWS CLI uses `credential_process` with `aws_signing_helper` and **`stacks/ops/aws/keeper.crt`**. CA private key stays in **`/opt/stack-secrets/keeper-ra-ca.key`**.

Full backup/restore guide: **[stacks/ops/BACKUP-RESTORE.md](ops/BACKUP-RESTORE.md)**.

### Grafana Alloy (collector only)

**`stacks/alloy`** runs [Grafana Alloy](https://grafana.com/docs/alloy/) on the `traefik` network. It does **not** run Grafana, Loki, or Prometheus on keeper.

- Host metrics (`prometheus.exporter.unix`)
- Traefik Prometheus metrics (`traefik:8082`, requires Traefik `metrics` entrypoint)
- Docker container logs → **Loki push URL**
- Metrics → **Prometheus remote_write URL**

Configure endpoints in **`stacks/alloy/secrets.enc.env`** (from **`stacks/alloy/.env.example`**). Typical destination: **Grafana Cloud** (separate Prometheus and Loki endpoints + API tokens).

```bash
sudo mkdir -p /opt/stacks/alloy
sudo cp stacks/alloy/.env.example /opt/stacks/alloy/.env
# edit with Grafana Cloud (or self-hosted) URLs and credentials
sudo stacks/ops/encrypt-stack-secrets.sh
```

Alloy UI listens on **127.0.0.1:12345** inside the container only (not exposed via Traefik).

## Automatic DNS (dnsweaver + Route53)

`goodmanners.services` is a Route53 zone. **`stacks/dnsweaver`** removes the manual step of adding an A record for each new service: [dnsweaver](https://github.com/maxfield-allison/dnsweaver) reads `Host(...)` out of Traefik router labels over its own socket-proxy, and [`route53-dnsweaver-webhook`](https://github.com/GoodMannersHosting/route53-dnsweaver-webhook) applies the result to the zone. Neither container is routed through Traefik and neither publishes a port.

A container with a normal Traefik router label needs nothing extra. To override the target for one container, add dnsweaver's own labels:

```yaml
labels:
  - dnsweaver.records.myapp.hostname=myapp.goodmanners.services
  - dnsweaver.records.myapp.type=A
  - dnsweaver.records.myapp.target=203.0.113.42
```

### IAM (Pulumi)

Route53 IAM and the GitHub Actions OIDC deploy role live in **`infra/aws`** (stack `prod`), separate from the Hetzner Pulumi project. The managed policy is zone-scoped (`ChangeResourceRecordSets`, `ListResourceRecordSets`, `GetHostedZone` on the `goodmanners.services` zone ARN, plus `ListHostedZones*` for SDK discovery).

**Bootstrap once** with an admin AWS principal (chicken-and-egg: GHA cannot create its own role until this exists):

```bash
cd infra/aws
npm ci
pulumi stack select prod   # or: pulumi stack init prod
# If the account already has a GitHub OIDC provider:
#   pulumi config set githubOidcProviderArn arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com
# Optional Roles Anywhere role for the webhook:
#   pulumi config set rolesAnywhereTrustAnchorArn arn:aws:rolesanywhere:us-east-1:ACCOUNT:trust-anchor/TA_ID
pulumi up
```

Copy the access key into the host env (never commit plaintext):

```bash
pulumi stack output route53HostedZoneId
pulumi stack output dnsweaverAccessKeyId
pulumi stack output dnsweaverSecretAccessKey --show-secrets
# set ROUTE53_HOSTED_ZONE_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY in /opt/stacks/dnsweaver/.env
sudo /opt/hcloud-security-cluster/stacks/ops/encrypt-stack-secrets.sh
```

Then wire CI:

1. Repo **variable** `AWS_DEPLOY_ROLE_ARN` = `pulumi stack output githubActionsDeployRoleArn`
2. Subsequent changes under `infra/aws/**` apply via [`.github/workflows/aws-infra.yml`](../.github/workflows/aws-infra.yml) using GitHub OIDC (`id-token: write`) against the S3 state backend `s3://pulumi-state-2e089842` and KMS `alias/pulumi-state` — no Pulumi Cloud token and no long-lived AWS keys in Actions
3. First apply the stack locally (so the deploy role exists with S3/KMS permissions), set `AWS_DEPLOY_ROLE_ARN`, then rely on CI

For Roles Anywhere instead of static keys: leave `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` blank, set `rolesAnywhereTrustAnchorArn` before `pulumi up`, point a profile in **`DNSWEAVER_AWS_CREDS_DIR`** at role ARN `dnsweaverRolesAnywhereRoleArn` (see **`stacks/ops/aws/credentials.example`**). The webhook image is distroless and runs as uid **65532**:

```bash
sudo chown -R 65532:65532 /opt/stacks/dnsweaver/aws
sudo chmod 0600 /opt/stacks/dnsweaver/aws/credentials
```

### Rollout

```bash
sudo mkdir -p /opt/stacks/dnsweaver/aws
sudo cp stacks/dnsweaver/.env.example /opt/stacks/dnsweaver/.env
sudo chmod 0600 /opt/stacks/dnsweaver/.env
openssl rand -hex 32                        # paste as DNSWEAVER_WEBHOOK_TOKEN
sudoedit /opt/stacks/dnsweaver/.env         # token, hosted zone id, AWS credentials
sudo stacks/ops/encrypt-stack-secrets.sh
```

**`DNSWEAVER_DRY_RUN=true`** ships as the default. Deploy, read `docker logs dnsweaver`, confirm the proposed records match the zone, then set it to `false` and re-encrypt.

**`DNSWEAVER_ADOPT_EXISTING=false`** is also the default, so the hostnames already in the zone (`auth`, `keeper`, `pdns`, `poweradmin`, `traefik`, `doco-cd`) stay under manual control. dnsweaver writes an ownership TXT beside each record it creates and only ever modifies or deletes those.

### Deletion and negative caching

**`DNSWEAVER_CLEANUP_ON_STOP=true`** deletes a record when its container stops, which includes the stop half of every Doco-CD redeploy. The zone's SOA minimum is currently **86400**, so a resolver that queries during that gap caches NXDOMAIN for up to a day. Lower the SOA minimum field (last value in the record) to `60` in the Route53 console before enabling cleanup on any hostname that matters, or set `DNSWEAVER_CLEANUP_ON_STOP=false` and let `DNSWEAVER_CLEANUP_ORPHANS` reap records on the reconcile pass instead.

## Security notes

- Authentik **worker** uses **`DOCKER_HOST=tcp://socket-proxy:2375`** (no raw docker.sock). Traefik uses its own socket-proxy service (`traefik-socket-proxy` container) on the same pattern.
- If Traefik deploy fails with **container name `/socket-proxy` already in use**, remove the orphan (`docker rm -f socket-proxy`) or tear down a legacy `traefik` compose project, then redeploy.
- OpenBao mounts **`OPENBAO_AWS_CREDS_DIR`** at **`/aws`** for KMS unseal.
- Traefik dashboard and Doco-CD UI: Authentik forward auth (`platform-admin`); webhook path rate-limited only.
- OpenBao ingress: Traefik rate limiting.
- **`stacks/ops/fix-fail2ban-ssh.sh`** — avoid SSH lockout; maintain **`admin-ips.txt`**.

- **Alloy** mounts **docker.sock** read-only for log discovery (same class of access as Doco-CD; no public UI).
- **dnsweaver** reaches Docker through its own `dnsweaver-socket-proxy` (`CONTAINERS`, `EVENTS`, `INFO`, `PING` only) on an `internal` network with no egress. The Route53 webhook sits on a separate network and never sees the Docker API.

OpenBao policy and OIDC files: repo root **`bao/`**.

## Dependency updates (Renovate)

[`renovate.json`](../renovate.json) — SHA-pinned images, grouped stack PRs, automerge on minor/patch. Restrict production webhooks to **`main`** so Renovate branch pushes do not repoint the deploy clone.
