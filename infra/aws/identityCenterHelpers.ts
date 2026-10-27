/** Authentik SCIM mapping: IC username = email (matches SAML NameID email). */
export function awsScimUserMappingExpression(): string {
  return [
    "return {",
    '    "photos": None,',
    '    "userName": request.user.email,',
    "}",
  ].join("\n");
}
