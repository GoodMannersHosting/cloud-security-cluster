import * as pulumi from "@pulumi/pulumi";
import * as vault from "@pulumi/vault";
import * as fs from "fs";
import * as path from "path";

const config = new pulumi.Config();
const baoRoot = path.resolve(__dirname, "../../bao");
const address = config.get("address") ?? "https://keeper.goodmanners.services";
const authentikClientId = config.requireSecret("authentikClientId");
// VAULT_TOKEN is set by the CI auth step (or locally via `export VAULT_TOKEN=...`).
// @pulumi/vault v6 requires token to be passed explicitly in ProviderArgs.
const vaultToken = process.env["VAULT_TOKEN"] ?? "";

// ─── Helpers ──────────────────────────────────────────────────────────────────

function readHcl(p: string): string {
  return fs.readFileSync(p, "utf-8");
}

function readJson<T = Record<string, any>>(p: string): T {
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function parseDuration(d: string): number {
  if (d.endsWith("m")) return parseInt(d) * 60;
  if (d.endsWith("h")) return parseInt(d) * 3600;
  if (d.endsWith("s")) return parseInt(d);
  return parseInt(d);
}

function serializeClaims(claims: Record<string, any>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(claims).map(([k, v]) => [
      k,
      Array.isArray(v) ? v.join(",") : String(v),
    ])
  );
}

function hclFiles(dir: string): string[] {
  return fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((f) => f.endsWith(".hcl"))
    : [];
}

function jsonFiles(dir: string): string[] {
  return fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((f) => f.endsWith(".json"))
    : [];
}

// ─── Root namespace ───────────────────────────────────────────────────────────
// VAULT_TOKEN is read from env by the provider automatically.

const rootProvider = new vault.Provider("root", { address, token: vaultToken, skipChildToken: true });

// Policies
const rootPoliciesDir = path.join(baoRoot, "policies");
for (const f of hclFiles(rootPoliciesDir)) {
  const name = f.replace(".hcl", "");
  new vault.Policy(
    `root-policy-${name}`,
    { name, policy: readHcl(path.join(rootPoliciesDir, f)) },
    { provider: rootProvider, import: name }
  );
}

// OIDC roles
const rootRolesDir = path.join(baoRoot, "roles");
for (const f of jsonFiles(rootRolesDir)) {
  const roleName = f.replace(".json", "");
  const raw = readJson(path.join(rootRolesDir, f));
  new vault.jwt.AuthBackendRole(
    `root-oidc-${roleName}`,
    {
      backend: "oidc",
      roleName,
      roleType: "oidc",
      userClaim: raw.user_claim,
      groupsClaim: raw.groups_claim,
      boundAudiences: authentikClientId.apply((id) => [id]),
      allowedRedirectUris: raw.allowed_redirect_uris ?? [],
      tokenPolicies: ([] as string[]).concat(raw.policies),
      boundClaims: raw.bound_claims ? serializeClaims(raw.bound_claims) : undefined,
      oidcScopes: raw.oidc_scopes ? raw.oidc_scopes.split(",") : undefined,
    },
    { provider: rootProvider, import: `auth/oidc/role/${roleName}` }
  );
}

// JWT CI role
const ciRaw = readJson(path.join(baoRoot, "jwt", "github-actions-ci.json"));
new vault.jwt.AuthBackendRole(
  "root-jwt-github-actions-ci",
  {
    backend: "jwt",
    roleName: "github-actions-ci",
    roleType: "jwt",
    userClaim: ciRaw.user_claim,
    boundAudiences: ciRaw.bound_audiences,
    boundSubject: ciRaw.bound_subject,
    boundClaims: ciRaw.bound_claims ? serializeClaims(ciRaw.bound_claims) : undefined,
    boundClaimsType: ciRaw.bound_claims_type,
    tokenPolicies: ([] as string[]).concat(ciRaw.token_policies),
    tokenTtl: ciRaw.token_ttl,
    tokenMaxTtl: ciRaw.token_max_ttl,
  },
  { provider: rootProvider, import: "auth/jwt/role/github-actions-ci" }
);

// ─── Namespace helper ─────────────────────────────────────────────────────────

interface K8sConfig {
  mount: string;
  host: pulumi.Output<string>;
  caCert: pulumi.Output<string>;
  reviewerJwt: pulumi.Output<string>;
  /** Set true on first run to import existing config + roles into state.
   * The AuthBackend mount itself is treated as pre-existing infrastructure
   * and is NOT managed by Pulumi (avoids requiring sys/mounts permissions
   * in the CI token and eliminates provider-side tune drift). */
  importExisting?: boolean;
}

function setupNamespace(
  ns: string,
  opts: { k8s?: K8sConfig } = {}
): void {
  const nsDir = path.join(baoRoot, "namespaces", ns);
  const provider = new vault.Provider(`ns-${ns}`, { address, namespace: ns, token: vaultToken, skipChildToken: true });

  // Policies
  const policiesDir = path.join(nsDir, "policies");
  for (const f of hclFiles(policiesDir)) {
    const name = f.replace(".hcl", "");
    new vault.Policy(
      `${ns}-policy-${name}`,
      { name, policy: readHcl(path.join(policiesDir, f)) },
      { provider, import: name }
    );
  }

  // OIDC roles
  const rolesDir = path.join(nsDir, "roles");
  for (const f of jsonFiles(rolesDir)) {
    const roleName = f.replace(".json", "");
    const raw = readJson(path.join(rolesDir, f));
    new vault.jwt.AuthBackendRole(
      `${ns}-oidc-${roleName}`,
      {
        backend: "oidc",
        roleName,
        roleType: "oidc",
        userClaim: raw.user_claim,
        groupsClaim: raw.groups_claim,
        boundAudiences: authentikClientId.apply((id) => [id]),
        allowedRedirectUris: raw.allowed_redirect_uris ?? [],
        tokenPolicies: ([] as string[]).concat(raw.policies),
        boundClaims: raw.bound_claims ? serializeClaims(raw.bound_claims) : undefined,
        oidcScopes: raw.oidc_scopes ? raw.oidc_scopes.split(",") : undefined,
      },
      { provider, import: `auth/oidc/role/${roleName}` }
    );
  }

  // Kubernetes config and roles
  // The AuthBackend mount is pre-existing infrastructure; Pulumi only manages
  // the config and roles so the CI token does not need sys/mounts permissions.
  if (opts.k8s) {
    const { mount, host, caCert, reviewerJwt, importExisting } = opts.k8s;
    const k8sDir = path.join(nsDir, "kubernetes");

    new vault.kubernetes.AuthBackendConfig(
      `${ns}-k8s-${mount}-config`,
      {
        backend: mount,
        kubernetesHost: host,
        kubernetesCaCert: caCert,
        tokenReviewerJwt: reviewerJwt,
      },
      {
        provider,
        ...(importExisting ? { import: mount } : {}),
      }
    );

    for (const f of jsonFiles(k8sDir)) {
      const roleName = f.replace(".json", "");
      const raw = readJson(path.join(k8sDir, f));
      new vault.kubernetes.AuthBackendRole(
        `${ns}-k8s-role-${roleName}`,
        {
          backend: mount,
          roleName,
          boundServiceAccountNames: raw.bound_service_account_names,
          boundServiceAccountNamespaces: raw.bound_service_account_namespaces,
          tokenPolicies: raw.policies,
          tokenTtl:
            typeof raw.ttl === "string" ? parseDuration(raw.ttl) : raw.ttl,
        },
        {
          provider,
          ...(importExisting ? { import: `auth/${mount}/role/${roleName}` } : {}),
        }
      );
    }
  }
}

// ─── Namespaces ───────────────────────────────────────────────────────────────

setupNamespace("homelab-dan", {
  k8s: {
    mount: "kubernetes-labops",
    host: config.requireSecret("kubeLabopsHost"),
    caCert: config.requireSecret("kubeLabopsCaCert"),
    reviewerJwt: config.requireSecret("kubeLabopsReviewerJwt"),
    importExisting: false,
  },
});
