#!/bin/bash
# Packer provisioner: bake the pinned toolkit and its boot prerequisites into the AMI.
# Runs as root on a fresh Ubuntu 24.04 build instance. Whatever is installed here is
# what AWS Marketplace scans, so the stack's bootstrap skips its own package install
# when it finds /opt/eat/BUILD_INFO.
set -euo pipefail

: "${EAT_VERSION:?}" "${EAT_REF:?}" "${EAT_COMMIT:?}"
export DEBIAN_FRONTEND=noninteractive

# First boot's cloud-init holds the apt lock while it runs its own package steps.
cloud-init status --wait >/dev/null 2>&1 || true

# Same needrestart setting the bootstrap writes - see the comment there. Baked so the
# deploy's own apt calls cannot restart dbus mid-Kubespray on this image either.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-eat-no-restart.conf <<'NREOF'
$nrconf{restart} = 'l';
$nrconf{kernelhints} = -1;
NREOF

# ---- OS patches + boot prerequisites ------------------------------------------
# full-upgrade, not upgrade, so kernel security updates that pull in new packages
# are applied too - Marketplace rejects images with unpatched critical/high CVEs.
apt-get update -qq
apt-get -y -qq full-upgrade
apt-get install -y -qq git curl openssl python3 python3-pip python3-venv \
  cloud-guest-utils jq unzip unattended-upgrades
apt-get -y -qq autoremove --purge
systemctl enable unattended-upgrades

# ---- AWS CLI v2 ----------------------------------------------------------------
# Stage 1 of the bootstrap needs it before anything else to fetch stage 2.
curl -sSL --max-time 300 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' \
  -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update >/dev/null
rm -rf /tmp/aws /tmp/awscliv2.zip
aws --version

# ---- pinned toolkit ------------------------------------------------------------
# Root-owned and read-only to users; the bootstrap copies it into the deploy user's
# home because the deploy writes config and generated secrets into the tree.
DEST=/opt/eat/enterprise-agent-toolkit
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf /tmp/eat-toolkit.tar.gz -C "$DEST" --no-same-owner
rm -f /tmp/eat-toolkit.tar.gz
[ -f "$DEST/deploy-agentic-stack.sh" ] \
  || { echo "FATAL: deploy-agentic-stack.sh missing from the toolkit tarball"; exit 1; }
# Not fatal: without it the stack falls back to in-cluster memory. But an image
# meant for the OpenSearch-backed listing should be built from a ref that has it.
[ -f "$DEST/core/lib/components/opensearch-controller.sh" ] \
  || echo "WARN: this ref has no OpenSearch provider; MemoryBackend=opensearch will fall back to in-cluster"
find "$DEST" -name '*.sh' -exec chmod 755 {} +
chown -R root:root /opt/eat
chmod -R go-w /opt/eat

jq -n --arg v "$EAT_VERSION" --arg r "$EAT_REF" --arg c "$EAT_COMMIT" \
  --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$(uname -r)" \
  '{toolkit_version:$v, toolkit_ref:$r, toolkit_commit:$c, built_at:$d, build_kernel:$k}' \
  > /opt/eat/BUILD_INFO
chmod 644 /opt/eat/BUILD_INFO
cat /opt/eat/BUILD_INFO
