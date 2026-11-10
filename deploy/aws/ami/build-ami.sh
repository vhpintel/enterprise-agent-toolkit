#!/bin/bash
# Build the toolkit AMI from a pinned git ref and publish its ID to SSM, so
# aws-agentic-toolkit.yaml can launch it with AmiId=<ssm parameter name>.
#
#   ./build-ami.sh --ref v1.3.0
#   ./build-ami.sh --ref feature/x --region us-west-2 --subnet-id subnet-... \
#       --ssh-interface session_manager --instance-profile packer-ssm
#   ./build-ami.sh --ref v1.3.0 --copy-to us-west-2,us-east-2
#
# Requires: packer >= 1.9, aws CLI v2, git, jq, and credentials for the build account.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git -C "$HERE" rev-parse --show-toplevel)

REF=HEAD
REGION=us-east-1
SSM_PARAM=/eat/ami/latest
SUBNET_ID=
SSH_INTERFACE=public_ip
INSTANCE_PROFILE=
COPY_TO=
PACKER=${PACKER:-packer}

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)              REF=$2; shift 2 ;;
    --region)           REGION=$2; shift 2 ;;
    --ssm-param)        SSM_PARAM=$2; shift 2 ;;
    --subnet-id)        SUBNET_ID=$2; shift 2 ;;
    --ssh-interface)    SSH_INTERFACE=$2; shift 2 ;;
    --instance-profile) INSTANCE_PROFILE=$2; shift 2 ;;
    --copy-to)          COPY_TO=$2; shift 2 ;;
    -h|--help)          usage ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

for c in "$PACKER" aws git jq; do
  command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }
done

# Marketplace rejects AMIs with encrypted snapshots, and account-level
# encryption-by-default silently encrypts the build volume regardless of
# encrypt_boot=false. Fail now rather than after a 20-minute build.
if [ "$(aws ec2 get-ebs-encryption-by-default --region "$REGION" \
        --query EbsEncryptionByDefault --output text)" = "True" ]; then
  echo "EBS encryption-by-default is ON in $REGION for this account - the AMI would be" >&2
  echo "encrypted and rejected by AWS Marketplace. Build in an account/region with it" >&2
  echo "off (aws ec2 disable-ebs-encryption-by-default --region $REGION)." >&2
  exit 1
fi

COMMIT=$(git -C "$REPO_ROOT" rev-parse --verify "$REF^{commit}")
VERSION=$(git -C "$REPO_ROOT" show "$COMMIT:core/version.txt" | jq -r .version)
# A dirty tree is irrelevant - git archive reads the commit - but say so, since
# uncommitted edits will NOT be in the image.
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  echo "note: working tree has uncommitted changes; they are not part of $COMMIT and will not be baked"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TARBALL="$WORK/eat-toolkit.tar.gz"
git -C "$REPO_ROOT" archive --format=tar.gz -o "$TARBALL" "$COMMIT"
echo "toolkit $VERSION @ ${COMMIT:0:12} ($REF): $(du -h "$TARBALL" | cut -f1)"

cd "$HERE"
"$PACKER" init eat-ami.pkr.hcl
"$PACKER" build \
  -var "region=$REGION" \
  -var "subnet_id=$SUBNET_ID" \
  -var "ssh_interface=$SSH_INTERFACE" \
  -var "iam_instance_profile=$INSTANCE_PROFILE" \
  -var "associate_public_ip=$([ "$SSH_INTERFACE" = public_ip ] && echo true || echo false)" \
  -var "toolkit_tarball=$TARBALL" \
  -var "toolkit_version=$VERSION" \
  -var "toolkit_ref=$REF" \
  -var "toolkit_commit=$COMMIT" \
  eat-ami.pkr.hcl

AMI=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
[[ "$AMI" == ami-* ]] || { echo "could not read AMI id from manifest.json" >&2; exit 1; }

publish() {  # $1 = region, $2 = ami
  # data-type aws:ec2:image makes SSM verify the AMI exists before accepting it.
  aws ssm put-parameter --region "$1" --name "$SSM_PARAM" --type String \
    --data-type aws:ec2:image --value "$2" --overwrite >/dev/null
  echo "  $1: $2 -> SSM $SSM_PARAM"
}

echo "built $AMI in $REGION"
publish "$REGION" "$AMI"

# For your own multi-region testing only. AWS Marketplace replicates the
# published product AMI to every listed region itself.
IFS=',' read -ra TARGETS <<< "$COPY_TO"
for R in "${TARGETS[@]}"; do
  [ -n "$R" ] || continue
  COPY=$(aws ec2 copy-image --region "$R" --source-region "$REGION" --source-image-id "$AMI" \
    --name "$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" \
              --query 'Images[0].Name' --output text)" \
    --copy-image-tags --query ImageId --output text)
  echo "  copying to $R as $COPY (waiting until available)"
  aws ec2 wait image-available --region "$R" --image-ids "$COPY"
  publish "$R" "$COPY"
done

echo
echo "Launch with: ParameterKey=AmiId,ParameterValue=$SSM_PARAM"
