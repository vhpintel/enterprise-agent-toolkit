# AWS deployment — CloudFormation

Provisions the toolkit on a single Intel Xeon EC2 instance with reasoning offloaded
to Amazon Bedrock and agent memory on Amazon OpenSearch Service. No GPU instance is
required.

| File | Purpose |
|---|---|
| `aws-agentic-toolkit.yaml` | The stack: EC2 control plane, OpenSearch domain, IAM, secrets, Bedrock endpoint |
| `validate-template.py` | Pre-flight checks — run after every edit, before uploading |
| `ami/` | Packer build of the toolkit AMI (`build-ami.sh`) — the image Marketplace lists |
| `docs/USAGE.md` | Buyer-facing usage guide: prerequisites, launch, access, external dependencies |
| `docs/IAM.md` | Least-privilege review of every permission the stack grants |

## What the stack creates

- **EC2** (Intel Xeon 6: `c8i`, `m8i` or `r8i`) running the full control plane: Kubernetes,
  LiteLLM gateway, guardrail, Agent Sandbox / OpenShell, observability.
- **Amazon OpenSearch Service** domain serving both memory tiers — VPC-attached,
  fine-grained access control, master password auto-generated into Secrets Manager.
- **IAM instance role** with least-privilege Bedrock invoke, scoped OpenSearch access
  and no long-lived access keys.
- **Optional `bedrock-runtime` interface endpoint** so model traffic stays on the AWS
  backbone rather than transiting NAT or a proxy.

Nothing network-level is created beyond the security groups and that one endpoint —
it deploys into an existing VPC and subnet.

## Prerequisites

- **A subnet with egress.** Container images and Kubernetes binaries are pulled at
  deploy time. Use one of:
  - a private subnet routed through a NAT gateway
  - a public subnet with `AssignPublicIp=true`
  - any subnet plus `HttpProxy`
- **Access to the toolkit source.** On the stock-Ubuntu path the bootstrap clones
  `ToolkitRepoUrl`. If that repo is private, set `ToolkitRepoTokenSecret`; if it is not
  reachable at all, stage a `git archive` tarball in S3 and set `CodeOverlayS3Bucket` /
  `CodeOverlayS3Key`. The Marketplace AMI avoids this - it carries the source in `/opt/eat`.
- **Proxy-only networks.** If the subnet's only route out is a corporate proxy (for
  example a Transit Gateway with no NAT or Internet gateway), set `HttpProxy`;
  without it the first `apt` call times out and the stack fails after a few minutes.
- **Bedrock model access** enabled for the account in the Bedrock region. The
  bootstrap's preflight check fails within minutes if it isn't.
- **The chosen c8i/m8i/r8i size offered** in the region and AZ, plus enough On-Demand
  Standard vCPU quota.

[docs/USAGE.md](docs/USAGE.md) covers these in buyer-facing detail. It also explains
when to set `CreateBedrockVpcEndpoint=false` (shared VPCs, existing endpoints).

## Deploying

The template exceeds the 51,200 B `--template-body` limit, so it must be uploaded to
S3 and deployed with `--template-url`:

```bash
aws s3 cp aws-agentic-toolkit.yaml s3://<bucket>/aws-agentic-toolkit/aws-agentic-toolkit.yaml --region <region>

aws cloudformation create-stack --region <region> --stack-name agentic-toolkit \
  --template-url https://<bucket>.s3.<region>.amazonaws.com/aws-agentic-toolkit/aws-agentic-toolkit.yaml \
  --capabilities CAPABILITY_IAM --on-failure DO_NOTHING \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxx \
    ParameterKey=SubnetId,ParameterValue=subnet-xxxxxxxx \
    ParameterKey=AdminIngressCidr,ParameterValue=10.0.0.0/8
```

Only those three parameters are required; everything else has a validated default.
Add `ParameterKey=HttpProxy,ParameterValue=http://proxy.example.com:3128` when the
subnet's only way out is a forward proxy, or `ParameterKey=AssignPublicIp,ParameterValue=true`
for a public subnet with no NAT.

`AmiId` selects the image, through an SSM parameter:

- **Prebuilt toolkit AMI** (production, and what Marketplace lists). Build it with
  `ami/build-ami.sh` and pass the SSM parameter it writes, e.g.
  `ParameterKey=AmiId,ParameterValue=/eat/ami/latest`. The toolkit is pinned under
  `/opt/eat`, so the bootstrap does no clone and no boot-time package install.
- **Stock Ubuntu 24.04 LTS** (the default, for development). The bootstrap installs
  prerequisites and clones `ToolkitRepoUrl` at `ToolkitGitRef`, then applies
  `CodeOverlayS3Bucket`/`Key` if set.

When the stack is launched from AWS Marketplace, `AmiId` is bound to the product AMI
automatically.

## Readiness

`CREATE_COMPLETE` means *verified*, not merely *booted*. The wait condition is only
signalled after the bootstrap passes four smoke tests: a Bedrock completion through
the gateway, OpenSearch cluster health, a short-term memory read-after-write, and a
non-empty seeded knowledge index. Endpoints are in the stack Outputs; the gateway API
key is written to Secrets Manager rather than an Output, since Outputs are readable by
anyone holding `cloudformation:DescribeStacks`.

## Troubleshooting

Every failure copies `/var/log/eat-bootstrap.log` to
`s3://<bucket>/eat-bootstrap-logs/<stack>/<instance-id>.log` and puts the last ~700
characters into the wait-condition reason, so `describe-stack-events` shows the cause
without needing a shell on the instance.

```bash
aws cloudformation describe-stack-events --region <region> --stack-name agentic-toolkit \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output text
```

Deploy with `--on-failure DO_NOTHING` so the instance survives a failed bootstrap for
inspection. Deleting the stack destroys the log source along with everything else.

## Editing

Run the validator after every change:

```bash
python3 validate-template.py
```

It checks YAML validity, that every `${...}` in a `!Sub` resolves, that both bootstrap
stages are syntactically valid bash, that UserData stays under the 16 KB EC2 cap, and
that no parameter is missing from a console parameter group.

The bootstrap is deliberately two-stage: stage 1 lives in `UserData` (capped at 16 KB
by EC2) and fetches stage 2 from the instance's own resource `Metadata`, which has no
such cap. Numbered notes in the template explain each non-obvious decision — read them
before changing proxy handling, memory wiring or the deploy invocation.
