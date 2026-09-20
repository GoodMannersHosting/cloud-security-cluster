import * as pulumi from "@pulumi/pulumi";
import * as vault from "@pulumi/vault";
import * as fs from "fs";
import * as path from "path";

const config = new pulumi.Config();
const baoRoot = path.resolve(__dirname, "../../bao");
const address = config.get("address") ?? "https://keeper.goodmanners.services";
// requireSecret's TypeScript overload widens to Output<string|undefined> in some
// SDK versions; cast to the correct runtime type to satisfy vault.jwt.AuthBackend.
const authentikClientId     = config.requireSecret("authentikClientId")     as unknown as pulumi.Output<string>;
const authentikClientSecret = config.requireSecret("authentikClientSecret") as unknown as pulumi.Output<string>;
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

// ─── Auth backend tune constants ──────────────────────────────────────────────
// Tune values are pinned explicitly to prevent perpetual provider drift
// (vault provider v6 does not write tune back to state after refresh).

/** Human interactive OIDC sessions via Authentik. Tokens are renewable. */
const TUNE_OIDC = {
  defaultLeaseTtl: "8h",
  maxLeaseTtl: "24h",
  tokenType: "default-service",
  listingVisibility: "unauth",  // surface in the UI login picker
} as const;

/** GitHub Actions CI JWT. Short-lived, non-renewable batch tokens. */
const TUNE_JWT_CI = {
  defaultLeaseTtl: "10m",
  maxLeaseTtl: "10m",
  tokenType: "batch",           // no token store; cannot be renewed
  listingVisibility: "hidden",
} as const;

/** Kubernetes service-account auth. SAs re-authenticate; no renewal needed. */
const TUNE_K8S = {
  defaultLeaseTtl: "1h",
  maxLeaseTtl: "24h",
  tokenType: "batch",
  listingVisibility: "hidden",
} as const;

// ─── Shared OIDC config (same Authentik app used by all namespaces) ────────────

const AUTHENTIK_DISCOVERY_URL = "https://auth.goodmanners.services/application/o/keeper/";

// ─── Root namespace ───────────────────────────────────────────────────────────

const rootProvider = new vault.Provider("root", {
  address,
  token: vaultToken,
  skipChildToken: true,
});

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

// Root OIDC auth backend — full config managed here
const rootOidcBackend = new vault.jwt.AuthBackend("root-oidc", {
  path: "oidc",
  type: "oidc",
  description: "Human interactive login via Authentik OIDC",
  oidcDiscoveryUrl: AUTHENTIK_DISCOVERY_URL,
  oidcClientId: authentikClientId,
  oidcClientSecret: authentikClientSecret,
  defaultRole: "reader",
  namespaceInState: true,
  tune: TUNE_OIDC,
}, { provider: rootProvider, import: "oidc" });

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

// Root JWT auth backend — GitHub Actions CI
const rootJwtBackend = new vault.jwt.AuthBackend("root-jwt", {
  path: "jwt",
  type: "jwt",
  description: "GitHub Actions OIDC JWT authentication for CI/CD",
  oidcDiscoveryUrl: "https://token.actions.githubusercontent.com",
  boundIssuer: "https://token.actions.githubusercontent.com",
  namespaceInState: true,
  tune: TUNE_JWT_CI,
}, { provider: rootProvider, import: "jwt" });

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
    // bound_subject is intentionally omitted: the @ORG_ID/REPO_ID format is not
    // a valid GitHub OIDC sub claim. Pinning is done via bound_claims using the
    // immutable repository_id and repository_owner_id numeric identifiers.
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
  /** Set true once to import a pre-existing auth backend mount into state.
   * After the first successful `pulumi up`, set back to false.
   * Config and roles are always written (idempotent PUT), never imported. */
  importBackend?: boolean;
}

interface NamespaceOpts {
  /** Import a pre-existing OIDC auth backend into state on first run. */
  importOidcBackend?: boolean;
  k8s?: K8sConfig;
}

function setupNamespace(ns: string, opts: NamespaceOpts = {}): void {
  const nsDir = path.join(baoRoot, "namespaces", ns);
  const provider = new vault.Provider(`ns-${ns}`, {
    address,
    namespace: ns,
    token: vaultToken,
    skipChildToken: true,
  });

  // Each namespace needs its own KV engine; mounts are namespace-local.
  new vault.Mount(
    `${ns}-secret`,
    {
      path: "secret",
      type: "kv-v2",
      description: `KV v2 secrets for ${ns}`,
    },
    { provider, import: "secret" }
  );

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

  // OIDC auth backend — full config managed here
  const oidcBackend = new vault.jwt.AuthBackend(`${ns}-oidc`, {
    path: "oidc",
    type: "oidc",
    description: `Human interactive login for ${ns} via Authentik OIDC`,
    oidcDiscoveryUrl: AUTHENTIK_DISCOVERY_URL,
    oidcClientId: authentikClientId,
    oidcClientSecret: authentikClientSecret,
    namespaceInState: true,
    tune: TUNE_OIDC,
  }, { provider, ...(opts.importOidcBackend ? { import: "oidc" } : {}) });

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

  // Kubernetes auth backend, config, and roles
  if (opts.k8s) {
    const { mount, host, caCert, reviewerJwt, importBackend } = opts.k8s;
    const k8sDir = path.join(nsDir, "kubernetes");

    const k8sBackend = new vault.AuthBackend(
      `${ns}-k8s-${mount}`,
      {
        type: "kubernetes",
        path: mount,
        description: `Kubernetes service-account auth for ${ns} (${mount} cluster)`,
        tune: TUNE_K8S,
      },
      { provider, ...(importBackend ? { import: `${mount}/` } : {}) }
    );

    // Config and roles are always written (idempotent PUT in OpenBao).
    // We never import them — if they pre-exist, the write is a no-op update.
    new vault.kubernetes.AuthBackendConfig(
      `${ns}-k8s-${mount}-config`,
      {
        backend: k8sBackend.path,
        kubernetesHost: host,
        kubernetesCaCert: caCert,
        tokenReviewerJwt: reviewerJwt,
      },
      { provider, dependsOn: [k8sBackend] }
    );

    for (const f of jsonFiles(k8sDir)) {
      const roleName = f.replace(".json", "");
      const raw = readJson(path.join(k8sDir, f));
      new vault.kubernetes.AuthBackendRole(
        `${ns}-k8s-role-${roleName}`,
        {
          backend: k8sBackend.path,
          roleName,
          boundServiceAccountNames: raw.bound_service_account_names,
          boundServiceAccountNamespaces: raw.bound_service_account_namespaces,
          tokenPolicies: raw.policies,
          tokenTtl:
            typeof raw.ttl === "string" ? parseDuration(raw.ttl) : raw.ttl,
        },
        { provider, dependsOn: [k8sBackend] }
      );
    }
  }
}

// ─── Namespaces ───────────────────────────────────────────────────────────────

setupNamespace("homelab-dan", {
  importOidcBackend: false,
  k8s: {
    mount: "kubernetes-labops",
    host: config.requireSecret("kubeLabopsHost"),
    caCert: config.requireSecret("kubeLabopsCaCert"),
    reviewerJwt: config.requireSecret("kubeLabopsReviewerJwt"),
    importBackend: false,
  },
});
