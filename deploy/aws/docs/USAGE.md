# Intel AI for Enterprise Agent Toolkit on AWS — usage guide

This product deploys a complete agentic AI control plane into your AWS account in about
60 minutes: Kubernetes, an OpenAI-compatible LiteLLM gateway, MCP tools and agent
memory. It runs on a single Intel Xeon 6 EC2 instance (c8i, m8i or r8i). Reasoning runs on
Amazon Bedrock models in your own account, so no GPU instance is needed.

Everything is created inside your VPC. The software has no inbound path from the
internet, and you reach it through AWS Systems Manager.

## What gets created

| Resource | Purpose | Main cost driver |
|---|---|---|
| EC2 instance, c8i/m8i/r8i (default r8i.24xlarge) | Kubernetes control plane, gateway, tools | Instance hours, 300 GiB gp3 root volume |
| Amazon OpenSearch Service domain (1 × r7i.large.search, Intel) | Short-term and long-term agent memory | Node hours, 100 GiB gp3 |
| bedrock-runtime VPC interface endpoint (optional) | Keeps model traffic private | Endpoint hours and data processed |
| Amazon Bedrock usage | Chat and embedding models | Tokens, billed by Bedrock |
| IAM role and instance profile, 3 security groups, 2 Secrets Manager secrets, a CloudFormation wait condition, an optional SNS topic | Access control and readiness | Negligible |

No VPC, subnet, NAT gateway or internet gateway is created. The stack deploys into
networking you already have.

## Before you launch

1. **Enable Bedrock model access.** In the Bedrock console, open **Model access** and
   enable the chat and embedding models you'll use, in the region you'll use them.
   The defaults are Claude Haiku 4.5, Claude Sonnet 4.5, Amazon Nova Lite and Titan
   Text Embeddings v2. The grant is per account and per region. The stack checks it
   within the first few minutes and fails with a clear message if it's missing.
2. **Pick a region where your instance type and Bedrock models are both available.**
   The default model IDs are US cross-region inference profiles (the `us.` prefix).
   In EU or APAC regions, pass `eu.` or `apac.` profile IDs in `BedrockChatModels`.
   To check instance availability (substitute your c8i/m8i/r8i size):
   ```bash
   aws ec2 describe-instance-type-offerings --region <region> \
     --location-type availability-zone --filters Name=instance-type,Values=r8i.24xlarge
   ```
3. **Check your EC2 vCPU quota.** r8i.24xlarge needs 96 vCPUs of the
   *Running On-Demand Standard instances* quota. The smallest allowed sizes
   (c8i.16xlarge, m8i.8xlarge, r8i.8xlarge) need 64, 32 and 32.
4. **Choose a subnet with outbound internet access.** It can be any one of:
   - a **private subnet whose default route is a NAT gateway** (recommended), or
   - a **public subnet** (default route to an internet gateway) with
     `AssignPublicIp=true`, or
   - any subnet whose only way out is a forward proxy, with `HttpProxy` set.

   A subnet with no egress makes the bootstrap fail within minutes.
5. **Decide on the Bedrock VPC endpoint.** Keep `CreateBedrockVpcEndpoint=true` if the
   VPC is dedicated to this product. Set it to `false` in either of these cases:
   - **The VPC already has a bedrock-runtime endpoint.** The private DNS names would
     conflict and the stack would fail.
   - **The VPC is shared with other workloads.** The endpoint's private DNS would route
     *their* Bedrock calls to an endpoint that only admits this instance.

   Bedrock then goes through your NAT or proxy instead.
6. **Make sure you can create IAM roles.** The stack creates a least-privilege
   instance role, so launching it needs `CAPABILITY_IAM`. The [IAM review](IAM.md)
   lists every permission granted.

## External dependencies

This product needs an internet connection to deploy. During the first boot it
downloads the following from public sources:

- Kubernetes components and Kubespray, from `github.com`, `raw.githubusercontent.com`
  and `dl.k8s.io`
- Container images, from `registry.k8s.io`, `docker.io`, `quay.io`, `ghcr.io` and
  `docker.litellm.ai`
- Helm charts, Python packages and Ansible collections, from the chart repositories,
  `pypi.org` and `galaxy.ansible.com`
- Ubuntu security updates, via `unattended-upgrades`, which runs continuously

Once deployed, the product calls these AWS services in your account: Amazon Bedrock,
Amazon OpenSearch Service, AWS Secrets Manager, AWS Systems Manager and AWS
CloudFormation. All of them are billed to you by AWS. None of the external
dependencies needs a separate account or payment.

## Launch

1. On the product page, choose **Continue to Subscribe**, accept the terms, then
   **Continue to Configuration**. Pick the version and region, choose the
   CloudFormation delivery option, and **Continue to Launch**.
2. CloudFormation opens with the template loaded. These parameters are required:

   | Parameter | Value |
   |---|---|
   | `VpcId` | Your VPC |
   | `SubnetId` | A subnet with egress (see step 4 above) |
   | `AdminIngressCidr` | Who may reach ports 80/443. Use your VPC CIDR or narrower. `0.0.0.0/0` is rejected |

   Every other parameter has a working default. The ones you're most likely to change:
   - `InstanceType`
   - `BedrockChatModels`
   - `AssignPublicIp`
   - `CreateBedrockVpcEndpoint`
   - `NotificationEmail`, which sends an email when the stack is ready
   - `DiagnosticsS3Bucket`, which copies the bootstrap log to S3
3. Under **Stack failure options**, choose **Preserve successfully provisioned
   resources**. If the bootstrap then fails, the instance stays up so you can inspect
   it.
4. Tick the IAM acknowledgement and choose **Submit**.

## When the stack is ready

`CREATE_COMPLETE` means the deployment has been *verified*, not just started. It's
signalled only after these checks pass:
- a Bedrock completion through the gateway
- OpenSearch health
- a memory read-after-write
- a populated sample knowledge index

All the commands below are in the stack's **Outputs** tab. You need the AWS CLI and
the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
# 1. Get the gateway API key (stored in Secrets Manager, never in Outputs)
aws secretsmanager get-secret-value --secret-id <stack>-gateway-api-key \
  --region <region> --query SecretString --output text

# 2. Tunnel the gateway to your machine (leave this running)
aws ssm start-session --target <InstanceId> --region <region> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["4000"],"localPortNumber":["4000"]}'

# 3. Call it like any OpenAI-compatible endpoint
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <api_key>" -H 'content-type: application/json' \
  -d '{"model":"us.anthropic.claude-haiku-4-5-20251001-v1:0",
       "messages":[{"role":"user","content":"Hello"}]}'
```

To get a shell, use `SsmSessionCommand`. No SSH key or open port is needed. To open
OpenSearch Dashboards, use `OpenSearchPortForwardCommand`, then browse to
`https://localhost:8443/_dashboards`. The OpenSearch credentials are in the secret
named by `OpenSearchMasterSecretArn`.

## Troubleshooting

When the bootstrap fails, the reason and the last lines of its log appear in the
stack events:

```bash
aws cloudformation describe-stack-events --stack-name <stack> --region <region> \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output text
```

| Symptom in the reason | Fix |
|---|---|
| `Bedrock model '...' is not enabled` | Enable model access (step 1 above), then delete and relaunch the stack |
| `apt-get update failed` / `git clone failed` / timeouts | The subnet has no egress (step 4 above) |
| Stack fails on `BedrockVpcEndpoint` | The VPC already has a bedrock-runtime endpoint. Set `CreateBedrockVpcEndpoint=false` |
| `InsufficientInstanceCapacity` / `VcpuLimitExceeded` | Choose another subnet or AZ, a smaller size, or request a quota increase |

The full log is at `/var/log/eat-bootstrap.log` on the instance. If you set
`DiagnosticsS3Bucket`, a copy is also at
`s3://<bucket>/eat-bootstrap-logs/<stack>/`.

## Security

- **No long-lived credentials.** The instance uses an IAM role, IMDSv2 is enforced,
  and the generated secrets live in Secrets Manager.
- **Encryption.** The root volume and the OpenSearch domain are encrypted at rest.
  OpenSearch also enforces TLS 1.2+ and fine-grained access control.
- **Network.** The instance has no public IP unless you set `AssignPublicIp`.
  Inbound access is limited to `AdminIngressCidr`, and SSH is only opened if you
  supply a `KeyName`.
- **Patching and vendor access.** The OS installs security updates automatically.
  The seller has no access to your instance.

## Deleting

Deleting the stack removes everything it created. **That includes the OpenSearch
domain and all agent memory**, which takes about 15–30 minutes. Take an OpenSearch
snapshot first if you need to keep the data.
