import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";
import { local } from "@pulumi/command";
import { createGithubOidc } from "./githubOidc";
import { createIdentityCenterAuthentik } from "./identityCenterAuthentik";
import { createRoute53Dnsweaver } from "./route53Dnsweaver";
import { createExternalDnsRoute53 } from "./externalDnsRoute53";

const config = new pulumi.Config();
const awsConfig = new pulumi.Config("aws");

const githubOrg = config.get("githubOrg") ?? "GoodMannersHosting@88983444";
const githubRepo =
  config.get("githubRepo") ?? "cloud-security-cluster@1166064097";
const allowedRefs = config.getObject<string[]>("allowedRefs") ?? [
  "refs/heads/main",
];
const hostedZoneName =
  config.get("hostedZoneName") ?? "goodmanners.services";
const existingOidcProviderArn = config.get("githubOidcProviderArn");
const rolesAnywhereTrustAnchorArn = config.get(
  "rolesAnywhereTrustAnchorArn",
);

const authentikUrl = config.get("authentikUrl");
const icManagementRoleArn = config.get("icManagementRoleArn");
const workloadAccountId = config.get("workloadAccountId");
const icAcsUrl = config.get("icAcsUrl");
const icAudience = config.get("icAudience");
const icScimUrl = config.get("icScimUrl");
const icAssignmentsEnabled = config.getBoolean("icAssignmentsEnabled") ?? false;
// Accounts the aws-admins / aws-viewers permission sets are assigned in.
// Defaults to just the workload account; set to include the org management
// account when SSO admin there should also come from Authentik.
const icAssignmentAccountIds =
  config.getObject<string[]>("icAssignmentAccountIds") ??
  (workloadAccountId ? [workloadAccountId] : []);

const oidc = createGithubOidc({
  githubOrg,
  githubRepo,
  allowedRefs,
  existingProviderArn: existingOidcProviderArn,
  icManagementRoleArn,
});

const dnsweaver = createRoute53Dnsweaver({
  hostedZoneName,
  rolesAnywhereTrustAnchorArn,
});

let assignmentsPending: pulumi.Output<boolean> | undefined;
let adminPermissionSetArn: pulumi.Output<string> | undefined;
let viewerPermissionSetArn: pulumi.Output<string> | undefined;
let authentikApplicationSlug: string | undefined;
let scimAttached: boolean | undefined;

// SAML-only apply needs acs + audience; the SCIM endpoint + token are added on a
// later apply once automatic provisioning is enabled in the IC console.
if (
  authentikUrl &&
  icManagementRoleArn &&
  workloadAccountId &&
  icAcsUrl &&
  icAudience
) {
  const managementProvider = new aws.Provider("ic-management", {
    region: (awsConfig.get("region") ?? "us-east-1") as aws.Region,
    assumeRole: { roleArn: icManagementRoleArn },
  });

  // SCIM token prefers the CI env var; local runs fall back to a stack secret.
  const scim = icScimUrl
    ? {
        url: icScimUrl,
        token:
          process.env.AUTHENTIK_SCIM_TOKEN !== undefined
            ? pulumi.secret(process.env.AUTHENTIK_SCIM_TOKEN)
            : config.requireSecret("icScimToken"),
      }
    : undefined;

  const icResult = createIdentityCenterAuthentik({
    icAcsUrl,
    icAudience,
    scim,
    assignmentAccountIds: icAssignmentAccountIds,
    managementProvider,
    icInstanceArn: config.get("icInstanceArn"),
    assignmentsEnabled: icAssignmentsEnabled,
  });
  assignmentsPending = icResult.assignmentsPending;
  adminPermissionSetArn = icResult.adminPermissionSetArn;
  viewerPermissionSetArn = icResult.viewerPermissionSetArn;
  authentikApplicationSlug = icResult.authentikApplicationSlug;
  scimAttached = icResult.scimAttached;
}

// Depend on the deploy role's policy attachment so this run's own
// permissions update (adding these resource ARNs) applies before we
// try to create them, avoiding a same-run race on a fresh account.
// IAM changes can take several seconds to propagate to an
// already-assumed-role session, so also wait a bit after the policy
// update before creating resources that need the new permissions.
const waitForIamPropagation = new local.Command("wait-for-iam-propagation", {
  create: "sleep 15",
}, { dependsOn: [oidc.deployPolicyAttachment] });

const externalDns = createExternalDnsRoute53(
  {
    hostedZoneName,
    accountNumber: config.require("accountNumber"),
    openbaoIamUserId: config.get("openbaoIamUserId"),
  },
  { dependsOn: [oidc.deployPolicyAttachment, waitForIamPropagation] },
);

export const awsRegion = awsConfig.get("region") ?? "us-east-1";
export const githubOidcProviderArn = oidc.providerArn;
export const githubActionsDeployRoleArn = oidc.deployRoleArn;
export const githubActionsDeployRoleName = oidc.deployRoleName;

export const route53HostedZoneId = dnsweaver.hostedZoneId;
export const route53HostedZoneName = hostedZoneName;
export const dnsweaverPolicyArn = dnsweaver.policyArn;
export const dnsweaverUserName = dnsweaver.userName;
export const dnsweaverAccessKeyId = dnsweaver.accessKeyId;
export const dnsweaverSecretAccessKey = dnsweaver.secretAccessKey;
export const dnsweaverRolesAnywhereRoleArn = dnsweaver.rolesAnywhereRoleArn;

export const icAssignmentsPending = assignmentsPending;
export const icAdminPermissionSetArn = adminPermissionSetArn;
export const icViewerPermissionSetArn = viewerPermissionSetArn;
export const icAuthentikApplicationSlug = authentikApplicationSlug;
export const icScimAttached = scimAttached;

export const externalDnsRoute53RoleArn = externalDns.roleArn;
export const externalDnsRoute53RoleName = externalDns.roleName;
