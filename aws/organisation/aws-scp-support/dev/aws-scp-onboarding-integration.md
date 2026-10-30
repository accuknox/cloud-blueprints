# AWS SCP Onboarding Integration

Current onboarding integration is limited to the push enforcement path only.

The nested SCP stack now deploys only:

- enforcement Lambda
- JWT authorizer Lambda
- HTTP API Gateway:
  - `POST /enforce-policy`
  - `GET /check`

It does not deploy reconciler or drift resources.

## Frontend Inputs

Frontend only needs to ask for:

- `EnableScpSupport`
- `ScpDefaultPolicyTargetId`

## Backend / Deploy Inputs

Backend or deploy pipeline must provide:

- `ScpSupportTemplateUrl`
- `ScpArtifactBucket`
- `ScpEnforcementLambdaS3Key`
- `ScpAuthorizerLambdaS3Key`
- optional `ScpEnforcementLambdaS3ObjectVersion`
- optional `ScpAuthorizerLambdaS3ObjectVersion`
- `ScpProjectName`
- `ScpApiStageName`
- `ScpEnableJwtAuthorizer`
- `ScpJwtJwksUrl`
- `ScpJwtExpectedIssuer`
- `ScpJwtExpectedAudience`
- optional `ScpJwtExpectedSubject`
- `ScpJwtRequiredTokenType`
- `ScpJwtRequiredClaims`
- `ScpJwtClockSkewSeconds`

## Minimum Required Parameters

When `EnableScpSupport=true`, onboarding must provide:

- `ScpSupportTemplateUrl`
- `ScpArtifactBucket`
- `ScpDefaultPolicyTargetId`

## Artifact Bucket Model

The Lambda zip files do not need a public bucket by default.

- The SCP stack is deployed in the AWS Organizations management account.
- That management account must be able to read the nested template and Lambda zip objects.
- Preferred model: keep the artifact bucket private and grant `s3:GetObject` to the deployment role/account.
- If artifacts are stored in a central AccuKnox bucket and the stack is deployed in a customer account, grant cross-account read-only access to the required object prefix.
- Avoid public-read unless there is no cleaner cross-account delivery path.
- If the bucket uses SSE-KMS, also grant decrypt permission on that KMS key.

## After Deployment

Backend should persist:

- `InvokeUrl`
- optionally `CheckUrl` if onboarding wants to store the explicit health endpoint too
- whether JWT authorizer is enabled
- expected audience/subject if token generation depends on them

During onboarding validation:

- call `${InvokeUrl}/check`
- require HTTP `200`
- require response body `{"status":"active"}` or equivalent JSON object with `status = active`
- block onboarding if the check call times out, is unreachable, returns non-200, or returns an invalid response body

Compatibility note:

- PPS now accepts both the base stage `InvokeUrl` and the legacy full `.../enforce-policy` URL
- if a base stage URL is stored, PPS appends `/enforce-policy` when it pushes SCP updates

## How Lambda Artifact Pickup Works

Initial create:

- the root onboarding template passes `ScpArtifactBucket` and the Lambda zip keys into the nested SCP stack
- the nested SCP stack uses those values in each Lambda `Code` block
- CloudFormation downloads the zip files from S3 and creates the functions

Update behavior:

- CloudFormation does not compare zip file contents at the same S3 key
- if `aws-scp-support/enforcement-lambda.zip` or `aws-scp-support/authorizer-lambda.zip` is overwritten in place and the stack keeps the same bucket + key with no object version change, an existing stack may keep the old Lambda code

To make updates deterministic, onboarding supports:

- `ScpEnforcementLambdaS3ObjectVersion`
- `ScpAuthorizerLambdaS3ObjectVersion`

Alternative:

- instead of passing object versions, backend can pass a new versioned S3 key on each release

## Current Scope

This file is intentionally limited to enforcement stack onboarding only.

Reconciler and drift detection integration are out of scope for the current CloudFormation rollout.
