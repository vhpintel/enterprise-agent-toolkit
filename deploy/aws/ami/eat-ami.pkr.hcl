# Builds the toolkit AMI that aws-agentic-toolkit.yaml launches. Run via build-ami.sh, which
# stages the pinned toolkit tarball and records the result in SSM.
#
# Output satisfies the AWS Marketplace AMI policies that are decided at build time:
# HVM, x86-64, EBS-backed, unencrypted snapshot, built in us-east-1 by default,
# no authorized keys / password logins (cleanup.sh), patched at build (provision.sh).

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "Build region. Marketplace requires the source AMI in us-east-1."
}

variable "instance_type" {
  type        = string
  default     = "r8i.large"
  description = "Build host only - the image itself runs on any c8i, m8i or r8i size."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Build subnet; needs egress for apt and the AWS CLI download. Empty = default VPC."
}

variable "associate_public_ip" {
  type    = bool
  default = true
}

variable "ssh_interface" {
  type        = string
  default     = "public_ip"
  description = "public_ip, private_ip, or session_manager (no inbound SSH needed)."
}

variable "iam_instance_profile" {
  type        = string
  default     = ""
  description = "Required for session_manager: a profile with AmazonSSMManagedInstanceCore."
}

variable "root_volume_gb" {
  type        = number
  default     = 20
  description = "Snapshot size. Kept small: the stack grows the root volume at launch."
}

variable "toolkit_tarball" {
  type        = string
  description = "git archive of the toolkit at toolkit_commit (made by build-ami.sh)."
}

variable "toolkit_version" {
  type = string
}

variable "toolkit_ref" {
  type = string
}

variable "toolkit_commit" {
  type = string
}

locals {
  build_stamp = formatdate("YYYYMMDDhhmm", timestamp())
}

source "amazon-ebs" "eat" {
  region        = var.region
  instance_type = var.instance_type

  ami_name        = "intel-agent-toolkit-${var.toolkit_version}-${local.build_stamp}"
  ami_description = "Intel AI for Enterprise Agent Toolkit ${var.toolkit_version} (${substr(var.toolkit_commit, 0, 12)}) on Ubuntu 24.04 LTS"

  # Canonical's official Ubuntu 24.04 LTS. Fine as a build base; the published
  # product AMI is this build's output, not Canonical's image.
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    owners      = ["099720108477"]
    most_recent = true
  }

  ssh_username                = "ubuntu"
  ssh_interface               = var.ssh_interface
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip
  iam_instance_profile        = var.iam_instance_profile

  # Marketplace rejects AMIs with encrypted snapshots. The stack encrypts the root
  # volume at launch instead (BlockDeviceMappings Encrypted: true).
  encrypt_boot = false
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = false
    delete_on_termination = true
  }

  ena_support  = true
  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name           = "intel-agent-toolkit-${var.toolkit_version}"
    Project        = "enterprise-agent-toolkit"
    ToolkitVersion = var.toolkit_version
    ToolkitRef     = var.toolkit_ref
    ToolkitCommit  = var.toolkit_commit
    BaseAmi        = "{{ .SourceAMI }}"
    BaseAmiName    = "{{ .SourceAMIName }}"
  }
  run_tags = {
    Name    = "packer-intel-agent-toolkit-build"
    Project = "enterprise-agent-toolkit"
  }
}

build {
  sources = ["source.amazon-ebs.eat"]

  provisioner "file" {
    source      = var.toolkit_tarball
    destination = "/tmp/eat-toolkit.tar.gz"
  }

  provisioner "shell" {
    script          = "${path.root}/provision.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "EAT_VERSION=${var.toolkit_version}",
      "EAT_REF=${var.toolkit_ref}",
      "EAT_COMMIT=${var.toolkit_commit}",
    ]
  }

  # Must be last: it removes the SSH key Packer is connected with.
  provisioner "shell" {
    script          = "${path.root}/cleanup.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
