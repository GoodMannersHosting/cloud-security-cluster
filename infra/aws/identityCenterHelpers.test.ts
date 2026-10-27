import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { awsScimUserMappingExpression } from "./identityCenterHelpers";

describe("awsScimUserMappingExpression", () => {
  it("maps userName to email and clears photos", () => {
    const expr = awsScimUserMappingExpression();
    assert.match(expr, /userName.*request\.user\.email/s);
    assert.match(expr, /photos.*None/s);
  });
});
