import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

export type ExternalDnsRoute53Args = {
  hostedZoneName: string;
  accountNumber: string;
};

export type ExternalDnsRoute53Result = {
  roleArn: pulumi.Output<string>;
  roleName: pulumi.Output<string>;
};

export function createExternalDnsRoute53(
  args: ExternalDnsRoute53Args,
): ExternalDnsRoute53Result {
  const zone = aws.route53.getZoneOutput({
    name: args.hostedZoneName,
    privateZone: false,
  });

  const policy = new aws.iam.Policy("external-dns-route53", {
    name: "openbao-external-dns-route53",
    description:
      "Route53 management for k8s ExternalDNS via OpenBao temporary credentials",
    policy: zone.arn.apply((arn) =>
      JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "ListAndChangeRecords",
            Effect: "Allow",
            Action: [
              "route53:ListResourceRecordSets",
              "route53:ChangeResourceRecordSets",
            ],
            Resource: arn,
          },
          {
            Sid: "ListZonesForDiscovery",
            Effect: "Allow",
            Action: ["route53:ListHostedZones", "route53:ListHostedZonesByName"],
            Resource: "*",
          },
          {
            Sid: "GetHostedZone",
            Effect: "Allow",
            Action: ["route53:GetHostedZone"],
            Resource: arn,
          },
        ],
      }),
    ),
    tags: {
      ManagedBy: "pulumi",
      Project: "keeper-aws-infra",
      Service: "external-dns",
    },
  });

  const role = new aws.iam.Role("external-dns-route53", {
    name: "openbao-external-dns-route53",
    description: "Assumed by OpenBao for ExternalDNS Route53 updates",
    assumeRolePolicy: JSON.stringify({
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: { AWS: `arn:aws:iam::${args.accountNumber}:root` },
          Action: ["sts:AssumeRole"],
        },
      ],
    }),
    tags: {
      ManagedBy: "pulumi",
      Project: "keeper-aws-infra",
      Service: "external-dns",
    },
  });

  new aws.iam.RolePolicyAttachment("external-dns-route53", {
    role: role.name,
    policyArn: policy.arn,
  });

  return {
    roleArn: role.arn,
    roleName: role.name,
  };
}
