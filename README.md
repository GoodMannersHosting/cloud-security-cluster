# aws-security-cluster

Security platform automation for **Good Manners Hosting**. The active deployment is a single Hetzner VPS (**keeper.goodmanners.services**) running Docker Compose: Traefik ingress, Authentik (GitHub SSO), OpenBao (AWS KMS auto-unseal), and [Doco-CD](https://github.com/kimdre/doco-cd) GitOps.

| Hostname | Service |
|----------|---------|
| `auth.goodmanners.services` | Authentik |
| `keeper.goodmanners.services` | OpenBao |
| `pdns.goodmanners.services` | PowerDNS API |
| `poweradmin.goodmanners.services` | Poweradmin UI |
| `traefik.goodmanners.services` | Traefik dashboard |
| `doco-cd.goodmanners.services` | Doco-CD (Authentik forward auth on UI only) |

**Start here:** [stacks/README.md](stacks/README.md)

**AWS IAM (Route53 dnsweaver + GitHub Actions OIDC):** [infra/aws](infra/aws/) — bootstrap once locally, then [`.github/workflows/aws-infra.yml`](.github/workflows/aws-infra.yml) applies via OIDC.

**GitOps:** [`.doco-cd.yml`](.doco-cd.yml) defines deploy order. Stack secrets live in git as **`stacks/*/secrets.enc.env`** (SOPS + age). [stacks/doco-cd/install-prod.sh](stacks/doco-cd/install-prod.sh) bootstraps the VPS; day-two ops in [stacks/ops/](stacks/ops/).

**OpenBao:** policies, roles, and OIDC in [bao/](bao/). File audit is declarative in [stacks/openbao/config/openbao.hcl.example](stacks/openbao/config/openbao.hcl.example); apply with [bao/enable-audit.sh](bao/enable-audit.sh).
