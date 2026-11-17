# IAM least-privilege review

The stack creates three IAM roles. `InstanceRole` is assumable only by
`ec2.amazonaws.com` and attached to the control plane instance through an instance
profile. `OpenSearchSlrFunctionRole` and `BedrockCheckFunctionRole` belong to one-shot
Lambdas and are described under [OpenSearchSlrFunctionRole](#opensearchslrfunctionrole) and
[BedrockCheckFunctionRole](#bedrockcheckfunctionrole). No IAM users or access keys are created, and none are requested from you.
Everything else in the stack that touches access control is a resource policy. Both
are listed below.

Every resource ARN is built with `${AWS::Partition}`, `${AWS::Region}` and
`${AWS::AccountId}`, so the scoping holds in any account. Where a wildcard
appears, the reason is given.

## InstanceRole

### AWS managed: `AmazonSSMManagedInstanceCore`

AWS's standard policy for Session Manager. It's how you get a shell and port-forwards
with no SSH key, no open port and no bastion. AWS recommends exactly this policy for
SSM-managed instances.

### `BedrockInvokeLeastPrivilege`

| Action | Resource | Why |
|---|---|---|
| `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream` | `foundation-model/*` in any region; `inference-profile/*` and `application-inference-profile/*` in this account | Gateway inference. The region is a wildcard because a cross-region inference profile (`us.…`) is authorized against the foundation model in every region it routes to. Only invoke actions are granted, so no models can be created, customized or deleted |
| `bedrock:ListFoundationModels`, `GetFoundationModel`, `ListInferenceProfiles`, `GetInferenceProfile` | `*` | Read-only discovery. These List actions don't support resource-level permissions |

### `MemoryBackendAccess`

| Action | Resource | Why |
|---|---|---|
| `es:ESHttpGet/Post/Put/Delete/Head/Patch` | `domain/<this stack's domain>/*` | Data-plane access to this stack's memory domain only. The toolkit authenticates with the fine-grained access control master user; this grant is for CLI and debugging use |
| `es:DescribeDomain`, `es:DescribeDomainConfig` | `domain/<this stack's domain>` | The toolkit waits for the domain to finish creating and reads its VPC endpoint |
| `secretsmanager:GetSecretValue` | `OpenSearchMasterSecret` only | Reads the OpenSearch master password at deploy time. It's never written to disk |
| `secretsmanager:PutSecretValue` | `GatewayApiKeySecret` only | Publishes the gateway key generated on the instance. Write-only, and limited to this one secret |

### `BootstrapSelfRead`

| Action | Resource | Why |
|---|---|---|
| `cloudformation:DescribeStackResource` | This stack only | Stage 1 of the bootstrap reads stage 2 from the instance's own resource metadata, because EC2 caps user data at 16 KB. It's read-only, limited to this stack, and is what `cfn-init` would use |

### `ReadCodeOverlay` — only if `CodeOverlayS3Bucket` is set (development only)

| Action | Resource | Why |
|---|---|---|
| `s3:GetObject` | The single overlay object | Read-only, one object |
| `kms:Decrypt`, `kms:DescribeKey` | `*`, with the condition `kms:ViaService = s3.<region>.amazonaws.com` | Needed when the bucket uses a customer-managed KMS key. The key ARN belongs to the bucket, not this stack, so it can't be named here. The condition means the key can only be used *through S3*, never called directly |

### `WriteBootstrapDiagnostics` — only if a diagnostics bucket is set

| Action | Resource | Why |
|---|---|---|
| `s3:PutObject` | `<bucket>/eat-bootstrap-logs/*` | Write-only, limited to one prefix. No read, list or delete |
| `kms:GenerateDataKey`, `kms:Decrypt`, `kms:DescribeKey` | `*`, with the `kms:ViaService` condition for S3 | Same reasoning as above |

### `PublishReadyNotification` — only if `NotificationEmail` is set

| Action | Resource | Why |
|---|---|---|
| `sns:Publish` | This stack's `ReadyTopic` only | The readiness email |

## OpenSearchSlrFunctionRole

Only created when `MemoryBackend=opensearch`. A VPC-attached OpenSearch domain needs the
account's OpenSearch service-linked role, which an account that has never used OpenSearch
does not have. A small Lambda creates it if it is missing and does nothing if it already
exists. The role is shared by every OpenSearch domain in the account, so it is never
deleted with the stack.

| Permission | Resource | Why |
|---|---|---|
| `iam:CreateServiceLinkedRole` | `AWSServiceRoleForAmazonOpenSearchService` only, with the condition `iam:AWSServiceName = opensearchservice.amazonaws.com` | Creates that one service-linked role and nothing else |
| `AWSLambdaBasicExecutionRole` (AWS managed) | CloudWatch Logs | The function's own logs |

The principal that deploys the stack also needs `iam:CreateServiceLinkedRole` and
`lambda:CreateFunction` for this to be created.

## BedrockCheckFunctionRole

Belongs to a one-shot Lambda that runs at the start of the stack, before the instance or
the OpenSearch domain are created. For every model in `BedrockChatModels` and
`BedrockEmbedModel` it asks Bedrock whether the model is usable in this account, and fails
the stack straight away with a clear message if one is not. Without it, a model that has not
been subscribed through AWS Marketplace only surfaces about 40 minutes into the deploy.
Set `BedrockModelAvailabilityCheck=false` to skip it.

| Permission | Resource | Why |
|---|---|---|
| `bedrock:GetFoundationModelAvailability` | `*` | Read-only status of a model in this account. The action does not support resource-level permissions |
| `AWSLambdaBasicExecutionRole` (AWS managed) | CloudWatch Logs | The function's own logs |

The instance role is deliberately **not** given `aws-marketplace:Subscribe`: it has no
resource-level scoping, so a compromised instance could subscribe the account to arbitrary
Marketplace products. Subscribing to a model is a one-time step for the account owner in the
Bedrock console.

## Resource policy: OpenSearch domain

The domain's access policy allows `es:ESHttp*` from `Principal: *` on this domain's
ARN. That will look broad to a reviewer, but it's the pattern AWS documents for
domains that use **fine-grained access control**:
- With fine-grained access control on, the internal user database is the
  authorization boundary, and every request must authenticate.
- The domain is **VPC-only**, so it has no public endpoint.
- Its security group admits only the control plane instance, on port 443.

## Not granted

The role has no `iam:*`, `ec2:*`, `s3:ListBucket`, `s3:DeleteObject`,
`secretsmanager:CreateSecret`, `bedrock:Create*` or `bedrock:Delete*`, and nothing
in any other stack or domain. The instance can't change its own permissions,
networking or infrastructure.
