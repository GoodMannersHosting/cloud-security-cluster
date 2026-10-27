import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const GITHUB_OIDC_URL = "https://token.actions.githubusercontent.com";
// Required by the IAM API; AWS no longer validates GitHub OIDC thumbprints.
const GITHUB_OIDC_THUMBPRINT = "6938fd4d98bab03faadb97b34396831e3780aea1";

export type GithubOidcArgs = {
  githubOrg: string;
  githubRepo: string;
  /** Branch refs allowed to assume the deploy role (e.g. refs/heads/main). */
  allowedRefs: string[];
  /** If set, reuse an existing account OIDC provider instead of creating one. */
  existingProviderArn?: string;
  /** Org management role Pulumi assumes for Identity Center APIs. */
  icManagementRoleArn?: string;
};

export type GithubOidcResult = {
  providerArn: pulumi.Output<string>;
  deployRoleArn: pulumi.Output<string>;
  deployRoleName: pulumi.Output<string>;
  /** The deploy role's policy attachment. Resources that need permissions
   * granted by this policy should `dependsOn` this to avoid racing the
   * policy update within the same Pulumi run. */
  deployPolicyAttachment: aws.iam.RolePolicyAttachment;
};

export function createGithubOidc(args: GithubOidcArgs): GithubOidcResult {
  const providerArn = resolveProviderArn(args.existingProviderArn);
  const role = createDeployRole(providerArn, args);
  const deployPolicyAttachment = attachDeployPolicy(role, args);
  return {
    providerArn,
    deployRoleArn: role.arn,
    deployRoleName: role.name,
    deployPolicyAttachment,
  };
}

function resolveProviderArn(
  existingArn: string | undefined,
): pulumi.Output<string> {
  if (existingArn) {
    return pulumi.output(existingArn);
  }
  const provider = new aws.iam.OpenIdConnectProvider("github-actions", {
    url: GITHUB_OIDC_URL,
    clientIdLists: ["sts.amazonaws.com"],
    thumbprintLists: [GITHUB_OIDC_THUMBPRINT],
    tags: { ManagedBy: "pulumi", Project: "keeper-aws-infra" },
  });
  return provider.arn;
}

function createDeployRole(
  providerArn: pulumi.Output<string>,
  args: GithubOidcArgs,
): aws.iam.Role {
  const subjects = args.allowedRefs.map(
    (ref) => `repo:${args.githubOrg}/${args.githubRepo}:ref:${ref}`,
  );
  return new aws.iam.Role("github-actions-aws-infra", {
    name: "github-actions-keeper-aws-infra",
    description:
      "GitHub Actions OIDC role to apply keeper-aws-infra Pulumi stack",
    assumeRolePolicy: providerArn.apply((arn) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: { Federated: arn },
            Action: "sts:AssumeRoleWithWebIdentity",
            Condition: {
              StringEquals: {
                "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
              },
              StringLike: {
                "token.actions.githubusercontent.com:sub": subjects,
              },
            },
          },
        ],
      }),
    ),
    tags: { ManagedBy: "pulumi", Project: "keeper-aws-infra" },
  });
}

function attachDeployPolicy(
  role: aws.iam.Role,
  args: GithubOidcArgs,
): aws.iam.RolePolicyAttachment {
  const policy = new aws.iam.Policy("github-actions-aws-infra", {
    name: "github-actions-keeper-aws-infra",
    // IAM policy descriptions are immutable; changing this forces replace.
    description: "Least privilege for Pulumi to manage keeper Route53 IAM + OIDC",
    policy: deployPolicyDocument(args.icManagementRoleArn),
    tags: { ManagedBy: "pulumi", Project: "keeper-aws-infra" },
  });
  return new aws.iam.RolePolicyAttachment("github-actions-aws-infra", {
    role: role.name,
    policyArn: policy.arn,
  });
}

const PULUMI_STATE_BUCKET = "pulumi-state-2e089842";
const PULUMI_STATE_KMS_KEY_ARN =
  "arn:aws:kms:us-east-1:417568418531:key/bfc0fa79-40b2-4b95-8880-8b937266af74";

function deployPolicyDocument(icManagementRoleArn?: string): string {
  // Named resources this stack owns. Create* still needs the target ARN.
  const resources = [
    "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com",
    "arn:aws:iam::*:role/github-actions-keeper-aws-infra",
    "arn:aws:iam::*:role/keeper-dnsweaver-route53-ra",
    "arn:aws:iam::*:user/keeper/keeper-dnsweaver-route53",
    "arn:aws:iam::*:policy/github-actions-keeper-aws-infra",
    "arn:aws:iam::*:policy/keeper-dnsweaver-route53",
    "arn:aws:iam::*:role/openbao-external-dns-route53",
    "arn:aws:iam::*:policy/openbao-external-dns-route53",
  ];
  const statements: object[] = [
      {
        Sid: "CallerIdentity",
        Effect: "Allow",
        Action: ["sts:GetCallerIdentity"],
        Resource: "*",
      },
      {
        Sid: "Route53ReadForZoneLookup",
        Effect: "Allow",
        Action: [
          "route53:GetHostedZone",
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:ListTagsForResource",
          "route53:GetChange",
        ],
        Resource: "*",
      },
      {
        Sid: "ListOidcProviders",
        Effect: "Allow",
        Action: ["iam:ListOpenIDConnectProviders"],
        Resource: "*",
      },
      {
        Sid: "ManageStackIam",
        Effect: "Allow",
        Action: [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:GetUser",
          "iam:TagUser",
          "iam:UntagUser",
          "iam:ListUserPolicies",
          "iam:ListAttachedUserPolicies",
          "iam:PutUserPolicy",
          "iam:GetUserPolicy",
          "iam:DeleteUserPolicy",
          "iam:AttachUserPolicy",
          "iam:DetachUserPolicy",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:SetDefaultPolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
          "iam:ListEntitiesForPolicy",
        ],
        Resource: resources,
      },
      {
        Sid: "PulumiStateBucket",
        Effect: "Allow",
        Action: ["s3:ListBucket", "s3:GetBucketLocation"],
        Resource: [`arn:aws:s3:::${PULUMI_STATE_BUCKET}`],
      },
      {
        Sid: "PulumiStateObjects",
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        Resource: [`arn:aws:s3:::${PULUMI_STATE_BUCKET}/*`],
      },
      {
        Sid: "PulumiStateKms",
        Effect: "Allow",
        Action: [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ],
        Resource: [PULUMI_STATE_KMS_KEY_ARN],
      },
  ];
  if (icManagementRoleArn) {
    statements.push({
      Sid: "AssumeIdentityCenterManagementRole",
      Effect: "Allow",
      Action: ["sts:AssumeRole"],
      Resource: [icManagementRoleArn],
    });
  }
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: statements,
  });
}
