#!/bin/bash
# =============================================================================
# EC2 User Data Script - Initial Setup
# =============================================================================

set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting EC2 initialization at $(date) ==="

PROJECT_NAME="${project_name}"
REPO_URL="${repository_url}"
REPO_BRANCH="${repository_branch}"

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
  nginx \
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
  libffi-devel

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

# Format and mount persistent models volume (if not already mounted)
# The models volume is attached at /dev/sdb
if [ -b /dev/sdb ]; then
    # Check if already formatted
    if ! blkid /dev/sdb > /dev/null 2>&1; then
        echo "Formatting models volume..."
        mkfs -t xfs /dev/sdb
    fi
    
    # Mount if not already mounted
    if ! mountpoint -q /opt/models; then
        echo "Mounting models volume..."
        mount /dev/sdb /opt/models
        
        # Add to fstab for persistence across reboots
        echo "/dev/sdb /opt/models xfs defaults,nofail 0 2" >> /etc/fstab
    fi
    
    echo "Models volume mounted at /opt/models"
fi

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

# Configure nginx to start on boot
systemctl enable nginx

# Log completion
echo "=== EC2 initialization completed at $(date) ===" > /opt/logs/initial-setup.log
echo "Project: $PROJECT_NAME" >> /opt/logs/initial-setup.log
echo "Repository: $REPO_URL" >> /opt/logs/initial-setup.log
echo "Branch: $REPO_BRANCH" >> /opt/logs/initial-setup.log
echo "Models Volume: Mounted at /opt/models" >> /opt/logs/initial-setup.log

# Reboot to apply all changes
reboot