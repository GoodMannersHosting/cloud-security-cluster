import * as aws from "@pulumi/aws";
import * as authentik from "@pulumi/authentik";
import * as pulumi from "@pulumi/pulumi";
import { awsScimUserMappingExpression } from "./identityCenterHelpers";

const APPLICATION_SLUG = "aws-iam-identity-center";
const PERMISSION_SET_SESSION_DURATION = "PT8H";
const DEFAULT_ADMIN_GROUP = "aws-admins";
const DEFAULT_VIEWER_GROUP = "aws-viewers";

/**
 * IC SCIM endpoint + bearer token. Both come from the console *after* SAML setup
 * is accepted and automatic provisioning is enabled. Omit for the first
 * (SAML-only) apply; add later to attach the SCIM backchannel provider.
 */
export type ScimConfig = {
  url: string;
  token: pulumi.Input<string>;
};

export type IdentityCenterAuthentikArgs = {
  icAcsUrl: string;
  icAudience: string;
  /** Provider that talks to the org management account. */
  managementProvider: aws.Provider;
  /** Accounts both permission sets get assigned in (when `assignmentsEnabled`). */
  assignmentAccountIds: string[];
  scim?: ScimConfig;
  /** Explicit IC instance ARN; otherwise discovered via `getInstances`. */
  icInstanceArn?: string;
  adminGroupName?: string;
  viewerGroupName?: string;
  /** When false (default), skip Identity Store lookups + AccountAssignments. */
  assignmentsEnabled?: boolean;
};

export type IdentityCenterAuthentikResult = {
  assignmentsPending: pulumi.Output<boolean>;
  adminPermissionSetArn: pulumi.Output<string>;
  viewerPermissionSetArn: pulumi.Output<string>;
  authentikApplicationSlug: string;
  scimAttached: boolean;
};

export function createIdentityCenterAuthentik(
  args: IdentityCenterAuthentikArgs,
): IdentityCenterAuthentikResult {
  const adminGroupName = args.adminGroupName ?? DEFAULT_ADMIN_GROUP;
  const viewerGroupName = args.viewerGroupName ?? DEFAULT_VIEWER_GROUP;
  const assignmentsEnabled = args.assignmentsEnabled ?? false;

  if (assignmentsEnabled && args.assignmentAccountIds.length === 0) {
    throw new Error(
      "assignmentsEnabled is true but assignmentAccountIds is empty",
    );
  }

  createAuthentikSide(args, adminGroupName, viewerGroupName);

  const permissionSets = createPermissionSets(args, adminGroupName, viewerGroupName);

  if (assignmentsEnabled) {
    for (const [groupName, permissionSetArn] of [
      [adminGroupName, permissionSets.adminPermissionSetArn],
      [viewerGroupName, permissionSets.viewerPermissionSetArn],
    ] as const) {
      createAccountAssignments(
        groupName,
        permissionSetArn,
        permissionSets,
        args,
      );
    }
  }

  return {
    assignmentsPending: pulumi.output(!assignmentsEnabled),
    adminPermissionSetArn: permissionSets.adminPermissionSetArn,
    viewerPermissionSetArn: permissionSets.viewerPermissionSetArn,
    authentikApplicationSlug: APPLICATION_SLUG,
    scimAttached: args.scim !== undefined,
  };
}

// ---------- Authentik side ----------

function createAuthentikSide(
  args: IdentityCenterAuthentikArgs,
  adminGroupName: string,
  viewerGroupName: string,
): void {
  const adminGroup = new authentik.Group(adminGroupName, {
    name: adminGroupName,
  });
  const viewerGroup = new authentik.Group(viewerGroupName, {
    name: viewerGroupName,
  });

  const samlProvider = createSamlProvider(args);
  const scimProvider = args.scim
    ? createScimProvider(args.scim, [adminGroup, viewerGroup])
    : undefined;
  createApplication(samlProvider, scimProvider);
}

function createSamlProvider(
  args: IdentityCenterAuthentikArgs,
): authentik.ProviderSaml {
  const authorizationFlow = authentik.getFlowOutput({
    slug: "default-provider-authorization-implicit-consent",
  });
  const invalidationFlow = authentik.getFlowOutput({
    slug: "default-provider-invalidation-flow",
  });
  const nameIdMapping = authentik.getPropertyMappingProviderSamlOutput({
    managed: "goauthentik.io/providers/saml/email",
  });
  const signingKp = authentik.getCertificateKeyPairOutput({
    name: "authentik Self-signed Certificate",
  });

  // NOTE: `default_name_id_policy` must also be set to
  // `urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` on this provider —
  // AWS IAM Identity Center rejects the `unspecified` NameID format with HTTP
  // 400. The goauthentik/authentik terraform provider (1.2.1) does not expose
  // that field yet, so it is a manual post-apply step (see README bootstrap).
  return new authentik.ProviderSaml(APPLICATION_SLUG, {
    name: "AWS IAM Identity Center",
    acsUrl: args.icAcsUrl,
    audience: args.icAudience,
    nameIdMapping: nameIdMapping.id,
    signingKp: signingKp.id,
    authorizationFlow: authorizationFlow.id,
    invalidationFlow: invalidationFlow.id,
    // AWS IAM Identity Center's ACS only accepts the HTTP-POST binding for the
    // SAML response; Authentik defaults to redirect, which AWS silently drops.
    spBinding: "post",
  });
}

function createScimProvider(
  scim: ScimConfig,
  scopeGroups: authentik.Group[],
): authentik.ProviderScim {
  const zzUserMapping = new authentik.PropertyMappingProviderScim(
    "zz-aws-scim-user",
    {
      name: "zz AWS SCIM User",
      expression: awsScimUserMappingExpression(),
    },
  );
  const defaultUserMapping = authentik.getPropertyMappingProviderScimOutput({
    managed: "goauthentik.io/providers/scim/user",
  });
  const defaultGroupMapping = authentik.getPropertyMappingProviderScimOutput({
    managed: "goauthentik.io/providers/scim/group",
  });

  return new authentik.ProviderScim(`${APPLICATION_SLUG}-scim`, {
    name: "AWS IAM Identity Center SCIM",
    url: scim.url,
    token: pulumi.secret(scim.token),
    compatibilityMode: "aws",
    // Only sync the AWS groups and their members — never all of Authentik.
    // Keeps service accounts (empty email -> empty SCIM userName) out of scope.
    excludeUsersServiceAccount: true,
    groupFilters: scopeGroups.map((g) => g.groupId),
    propertyMappings: [
      defaultUserMapping.id,
      zzUserMapping.propertyMappingProviderScimId,
    ],
    propertyMappingsGroups: [defaultGroupMapping.id],
  });
}

function createApplication(
  samlProvider: authentik.ProviderSaml,
  scimProvider: authentik.ProviderScim | undefined,
): authentik.Application {
  return new authentik.Application(APPLICATION_SLUG, {
    name: "AWS IAM Identity Center",
    slug: APPLICATION_SLUG,
    protocolProvider: samlProvider.providerSamlId.apply(parseProviderId),
    backchannelProviders: scimProvider
      ? scimProvider.providerScimId.apply((id) => [parseProviderId(id)])
      : [],
  });
}

/** Authentik provider ids are numeric strings; fail loudly rather than send NaN to the API. */
function parseProviderId(id: string): number {
  const parsed = Number(id);
  if (Number.isNaN(parsed)) {
    throw new Error(`Expected a numeric Authentik provider id, got "${id}"`);
  }
  return parsed;
}

// ---------- Permission sets ----------

type PermissionSetsResult = {
  instanceArn: pulumi.Output<string>;
  identityStoreId: pulumi.Output<string>;
  adminPermissionSetArn: pulumi.Output<string>;
  viewerPermissionSetArn: pulumi.Output<string>;
};

function createPermissionSets(
  args: IdentityCenterAuthentikArgs,
  adminGroupName: string,
  viewerGroupName: string,
): PermissionSetsResult {
  const instances = aws.ssoadmin.getInstancesOutput({
    provider: args.managementProvider,
  });
  const instanceArn = args.icInstanceArn
    ? pulumi.output(args.icInstanceArn)
    : instances.arns.apply((arns) => {
        if (!arns[0]) throw new Error("No IAM Identity Center instance found");
        return arns[0];
      });
  const identityStoreId = instances.identityStoreIds.apply((ids) => {
    if (!ids[0]) throw new Error("No IAM Identity Center identity store found");
    return ids[0];
  });

  return {
    instanceArn,
    identityStoreId,
    adminPermissionSetArn: createPermissionSet(
      adminGroupName,
      instanceArn,
      "arn:aws:iam::aws:policy/AdministratorAccess",
      args.managementProvider,
    ),
    viewerPermissionSetArn: createPermissionSet(
      viewerGroupName,
      instanceArn,
      "arn:aws:iam::aws:policy/ReadOnlyAccess",
      args.managementProvider,
    ),
  };
}

function createPermissionSet(
  name: string,
  instanceArn: pulumi.Output<string>,
  managedPolicyArn: string,
  provider: aws.Provider,
): pulumi.Output<string> {
  const permissionSet = new aws.ssoadmin.PermissionSet(
    name,
    { name, instanceArn, sessionDuration: PERMISSION_SET_SESSION_DURATION },
    { provider },
  );
  new aws.ssoadmin.ManagedPolicyAttachment(
    `${name}-managed-policy`,
    { instanceArn, permissionSetArn: permissionSet.arn, managedPolicyArn },
    { provider },
  );
  return permissionSet.arn;
}

// ---------- Assignments ----------

/** One `GROUP -> permission set -> account` assignment per configured account. */
function createAccountAssignments(
  groupName: string,
  permissionSetArn: pulumi.Output<string>,
  permissionSets: PermissionSetsResult,
  args: IdentityCenterAuthentikArgs,
): void {
  const group = aws.identitystore.getGroupOutput(
    {
      identityStoreId: permissionSets.identityStoreId,
      alternateIdentifier: {
        uniqueAttribute: {
          attributePath: "DisplayName",
          attributeValue: groupName,
        },
      },
    },
    { provider: args.managementProvider },
  );

  for (const accountId of args.assignmentAccountIds) {
    new aws.ssoadmin.AccountAssignment(
      `${groupName}-assignment-${accountId}`,
      {
        instanceArn: permissionSets.instanceArn,
        permissionSetArn,
        principalId: group.groupId,
        principalType: "GROUP",
        targetId: accountId,
        targetType: "AWS_ACCOUNT",
      },
      { provider: args.managementProvider },
    );
  }
}
