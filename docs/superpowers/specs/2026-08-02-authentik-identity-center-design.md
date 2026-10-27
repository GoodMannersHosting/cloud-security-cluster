# Authentik as IAM Identity Center IdP (Pulumi)

Date: 2026-08-02  
Status: approved for planning  
Scope: Pulumi-managed Authentik SAML+SCIM application for AWS IAM Identity Center, plus IC external IdP, permission sets, and group assignments in the existing org Identity Center. Existing Authentik YAML blueprints stay until a later migration.

## Problem

AWS access today is not driven by Authentik groups through IAM Identity Center. Authentik apps and groups live in YAML blueprints under `authentik/blueprints/`; AWS infra in `infra/aws` covers Route53 and GitHub OIDC only. We want Authentik as the org Identity Center external IdP (SAML auth + SCIM provisioning), with permission sets and account assignments managed as IaC in the same Pulumi stack, using an Authentik API token sourced from OpenBao at deploy time.

## Goals

- Use Authentik as the external SAML IdP for the already-enabled org IAM Identity Center (identity-source switch is a one-time bootstrap; see Approach).
- Provision users/groups into Identity Center via SCIM from Authentik.
- Create Authentik groups `aws-admins` and `aws-viewers`, plus the SAML and SCIM application/provider resources in Pulumi (`@pulumi/authentik`).
- Create IC permission sets: `AWSAdministratorAccess` for `aws-admins`, `AWSReadOnlyAccess` for `aws-viewers`.
- Assign both permission sets to the current workload account (more accounts later via config).
- Live in the existing `infra/aws` / `prod` stack; CI fetches Authentik API + SCIM tokens from OpenBao before `pulumi up`.

## Non-goals

- Migrating existing blueprints (OpenBao, Doco-CD, Poweradmin, brand, platform-admin) into Pulumi.
- Enabling or creating the Identity Center instance (already exists in the org management account).
- Multi-account assignment lists on day one (config will allow expansion later).
- Managing which humans belong to `aws-admins` / `aws-viewers` (operators add membership in Authentik).
- Replacing dnsweaver / GitHub OIDC resources in this stack.

## Approach

Dual-provider module in `infra/aws`: `@pulumi/aws` (workload account default + AssumeRole into org management for SSO Admin / Identity Store APIs) and `@pulumi/authentik` (official bridged provider; not the older `@pulumiverse/authentik` name). Document two-phase group assignment behavior inside the module (SCIM groups may not exist until after the first successful sync).

**AWS limitation:** Changing the IAM Identity Center identity source to an external SAML IdP and enabling SCIM are not available as first-class Pulumi/Terraform resources today (console / support-assisted APIs only). Treat that as a one-time bootstrap that yields ACS URL, audience, SCIM endpoint, and SCIM access token. Pulumi then owns Authentik SAML/SCIM, IC permission sets, and account assignments, consuming those bootstrap values from config / OpenBao.

## Architecture

```text
GitHub Actions (aws-infra.yml)
  OIDC --> AWS deploy role (workload account)
       |-> AssumeRole --> org management (Identity Center APIs)
       |-> OpenBao --> Authentik API token
       |-> pulumi up (infra/aws, stack prod)

Pulumi module: identityCenterAuthentik.ts
  Authentik (@pulumi/authentik)
    groups: aws-admins, aws-viewers
    SAML provider + application (ACS/issuer from IC)
    SCIM provider bound to that app

  AWS (@pulumi/aws, management provider)
    lookup existing org IC instance
    permission sets + account assignments
      (after SCIM sync; second apply if groups not yet present)

  One-time bootstrap (console; not Pulumi)
    change IC identity source -> external IdP
    upload Authentik IdP metadata; enable SCIM
    store ACS/audience/SCIM URL in Pulumi config;
    store SCIM token (+ Authentik API token) in OpenBao

Existing blueprints unchanged.
```

## Components

### `infra/aws/identityCenterAuthentik.ts`

Factory module in the same style as `githubOidc.ts` / `route53Dnsweaver.ts`. Owns Authentik groups, SAML/SCIM app, and AWS IC IdP, permission sets, and assignments.

Inputs (config): Authentik URL, management-account role ARN to assume, workload account ID, optional IC instance ARN (or discover via `getInstances`), group and permission-set names with defaults above.

### Dual AWS providers

- Default provider: workload account (existing Route53 / OIDC resources unchanged).
- Second `aws.Provider`: assumes into the org management account for `ssoadmin` and Identity Store APIs.

### Authentik provider

`@pulumi/authentik` configured from URL + token. CI injects the token from OpenBao into env / provider config (not stored long-term in Pulumi config or git). Local runs export the same env vars.

### CI (`.github/workflows/aws-infra.yml`)

After AWS OIDC login: fetch Authentik token from OpenBao, set provider credentials, then `pulumi up`. Extend the deploy path with `sts:AssumeRole` into the management IC role. Exact OpenBao auth method for GHA is an implementation detail of the plan (align with existing Bao patterns where possible).

### Config (`Pulumi.prod.yaml`)

Non-secret knobs only: Authentik URL, management role ARN, workload account ID, optional IC instance ARN, group/permission-set names. No Authentik token or SCIM bearer in git.

## Apply order

0. **Bootstrap (once, outside Pulumi):** In the org management account console, change Identity Center identity source to External IdP; download SP metadata (ACS + audience). Create Authentik SAML app (or let first Pulumi apply create it once ACS/audience are in config); download Authentik IdP metadata; upload to IC; enable SCIM; store SCIM endpoint URL in Pulumi config and SCIM token in OpenBao.
1. Lookup org IC instance (management provider) for instance ARN / identity store ID.
2. Create IC permission sets and attach AWS managed policies (`AWSAdministratorAccess`, `AWSReadOnlyAccess`). Permission sets are org-scoped; account targeting happens only in assignments (step 6).
3. Create Authentik groups `aws-admins` / `aws-viewers` (idempotent if already present).
4. Create Authentik SAML provider + application using config ACS URL + audience; NameID = email mapping; signing cert from Authentik.
5. Create Authentik SCIM provider (compatibility mode `aws`) with SCIM URL from config and token from OpenBao; attach as backchannel provider on the AWS application. Align SCIM `userName` with SAML NameID (email).
6. Look up Identity Store groups by name after SCIM sync. If missing on first apply, skip assignments and set stack output `assignmentsPending: true`. Second `pulumi up` (after SCIM has synced groups) creates account assignments for the workload account ID from config.

Document this two-phase behavior in the module and stack docs.

## Secrets

| Secret | Source | Destination |
|--------|--------|-------------|
| Authentik API token | OpenBao (fetched at deploy via GHA JWT) | Pulumi Authentik provider (`AUTHENTIK_TOKEN`, not committed) |
| IC SCIM bearer | OpenBao (written once after console SCIM enable) | Authentik SCIM provider resource |

No long-lived AWS access keys for this path. Mask tokens in CI logs.

## Failure modes

| Symptom | Likely cause |
|---------|----------------|
| Authentik provider auth failure | Missing/expired Bao token or wrong URL |
| SSO / Identity Store AccessDenied | Deploy role cannot AssumeRole into management IC role, or role lacks SSO Admin permissions |
| External IdP / SAML login fails | ACS/issuer/metadata mismatch between Authentik and IC |
| SCIM users/groups missing | SCIM provider misconfigured or token invalid |
| `assignmentsPending: true` after first apply | Expected until SCIM sync; re-run `pulumi up` |
| Unexpected deletes of Route53/OIDC | Module incorrectly using default provider for IC resources — keep IC resources on management provider |

## Verification

- `pulumi preview` (workflow_dispatch `preview_only`) shows Authentik + IC resources with no unexpected deletes of dnsweaver/OIDC.
- After first `up`: Authentik app exists; IC shows Authentik as external IdP; SCIM enabled; permission sets present.
- After SCIM sync + second `up` if needed: Identity Store has `aws-admins` / `aws-viewers`; account assignments exist on the workload account.
- Smoke: member of `aws-admins` gets AdministratorAccess via SSO; `aws-viewers` gets ReadOnlyAccess; member of neither is denied.
- No Authentik API token or SCIM bearer in git or unmasked workflow logs.

## Documentation updates (implementation)

- `infra/aws` README or stack comments: dual-provider, OpenBao token, two-phase assignments.
- `Pulumi.prod.yaml` comments for new config keys.
- Brief note in `stacks/README.md` or root README that AWS SSO path is Authentik → IC via this module (blueprints still own other apps).

## Deferred

- Migrating remaining Authentik blueprints into Pulumi.
- Config-driven multi-account assignment lists.
- Automating OpenBao token rotation details beyond “fetch at deploy.”
- Changing or replacing the existing Identity Center instance.
