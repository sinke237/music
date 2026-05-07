#!/bin/bash
# =============================================================================
# EC2 User Data Script - Wan2.2 Instance (g5.48xlarge)
# Runs Wan2.2 video generation service (distributed inference)
# =============================================================================

set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting Wan2.2 Instance initialization at $(date) ==="

PROJECT_NAME="${project_name}"
REPO_URL="${repository_url}"
REPO_BRANCH="${repository_branch}"
INSTANCE_INDEX="${instance_index}"
TOTAL_WAN_INSTANCES="${total_wan_instances}"

# Update system
yum update -y

# Install essential packages
yum install -y \
  git \
  wget \
  curl \
  vim \
  htop \
  tmux \
  python3.11 \
  python3.11-devel \
  python3.11-pip \
  nodejs \
  npm \
  ffmpeg \
  ffmpeg-devel \
  gcc \
  gcc-c++ \
  make \
  openssl-devel \
  zlib-devel \
  bzip2-devel \
  readline-devel \
  sqlite-devel \
  llvm \
  ncurses-devel \
  xz \
  tk-devel \
  libxml2-devel \
  libffi-devel \
  openmpi-devel \
  nfs-utils

# Install uv package manager
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Make uv available system-wide
ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv || true
ln -sf "$HOME/.local/bin/uvx" /usr/local/bin/uvx || true

# Configure git
git config --global user.email "deploy@${project_name}.com"
git config --global user.name "Deploy Bot"
git config --global init.defaultBranch main

# Create application directories
mkdir -p /opt/app
mkdir -p /opt/logs
mkdir -p /opt/models

# Set ownership
if id "ec2-user" &>/dev/null; then
    chown -R ec2-user:ec2-user /opt/app
    chown -R ec2-user:ec2-user /opt/logs
    chown -R ec2-user:ec2-user /opt/models
    
    # Also set for ubuntu if it exists
    if id "ubuntu" &>/dev/null; then
        chown -R ubuntu:ubuntu /opt/app
        chown -R ubuntu:ubuntu /opt/logs
        chown -R ubuntu:ubuntu /opt/models
    fi
fi

chmod 755 /opt/app
chmod 755 /opt/logs
chmod 755 /opt/models

# Clone repository if specified
if [ -n "$REPO_URL" ]; then
    echo "Cloning repository: $REPO_URL"
    cd /opt/app
    git clone -b "$REPO_BRANCH" "$REPO_URL" music || echo "Repository clone failed, will be cloned manually later"
fi

# Configure distributed inference environment
echo "Configuring distributed inference environment..."
cat >> /etc/environment << EOF
WAN_NODE_RANK=${instance_index}
WAN_WORLD_SIZE=${total_wan_instances}
MASTER_ADDR=PRIMARY_WAN_NODE_IP
EOF

# Log completion
echo "=== Wan2.2 Instance initialization completed at $(date) ===" > /opt/logs/initial-setup.log
echo "Role: Wan2.2 Instance" >> /opt/logs/initial-setup.log
echo "Instance Index: $INSTANCE_INDEX" >> /opt/logs/initial-setup.log
echo "Total Wan Instances: $TOTAL_WAN_INSTANCES" >> /opt/logs/initial-setup.log
echo "Node Rank: $INSTANCE_INDEX" >> /opt/logs/initial-setup.log
echo "World Size: $TOTAL_WAN_INSTANCES" >> /opt/logs/initial-setup.log
echo "Project: $PROJECT_NAME" >> /opt/logs/initial-setup.log
echo "Repository: $REPO_URL" >> /opt/logs/initial-setup.log
echo "Branch: $REPO_BRANCH" >> /opt/logs/initial-setup.log
echo "Models Volume: Shared via NFS from ACE instance" >> /opt/logs/initial-setup.log

# Reboot to apply all changes
reboot