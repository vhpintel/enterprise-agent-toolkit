#!/bin/bash
# Packer provisioner, run last: leave nothing instance- or builder-specific in the
# image. Each step maps to an AWS Marketplace AMI security policy.
set -euo pipefail

# No password-based SSH, no password-based root login.
cat > /etc/ssh/sshd_config.d/00-eat-marketplace.conf <<'EOF'
# AWS Marketplace AMI policy. sshd uses the first value it reads, and 00- sorts
# ahead of cloud-init's 50-cloud-init.conf.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 644 /etc/ssh/sshd_config.d/00-eat-marketplace.conf
sshd -t
passwd -l root

# No authorized public keys - including the temporary one Packer connected with.
find /root /home -path '*/.ssh/authorized_keys' -type f -delete

# Host keys and machine identity are regenerated per instance by cloud-init.
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --machine-id 2>/dev/null || {
  cloud-init clean --logs
  truncate -s 0 /etc/machine-id
}

# Build residue: shell history, package caches, logs, temp files.
rm -f /root/.bash_history /home/*/.bash_history
apt-get clean
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f ! -path '/var/log/journal/*' -exec truncate -s 0 {} +
rm -rf /tmp/* /var/tmp/*
sync
