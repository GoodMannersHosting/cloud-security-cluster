import * as pulumi from "@pulumi/pulumi";
import { local } from "@pulumi/command";
import { createGithubOidc } from "./githubOidc";
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

const oidc = createGithubOidc({
  githubOrg,
  githubRepo,
  allowedRefs,
  existingProviderArn: existingOidcProviderArn,
});

const dnsweaver = createRoute53Dnsweaver({
  hostedZoneName,
  rolesAnywhereTrustAnchorArn,
});

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
export const externalDnsRoute53RoleArn = externalDns.roleArn;
export const externalDnsRoute53RoleName = externalDns.roleName;
