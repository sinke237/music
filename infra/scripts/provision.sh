#!/bin/bash
# =============================================================================
# Infrastructure Provisioning Script (Idempotent)
# Creates all AWS resources and deploys the application
# Safe to run multiple times
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$INFRA_DIR/terraform"
KEY_PATH="$HOME/babaNaTrue/ema-practice.pem"
EC2_IP_FILE="$INFRA_DIR/.ec2_ip"
TFVARS_FILE="${TFVARS_FILE:-}"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1 Already exists/configured"
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check if terraform is installed
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed. Please install it first."
        log_info "Download from: https://www.terraform.io/downloads"
        exit 1
    fi
    
    # Check if AWS CLI is configured
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS CLI is not configured. Please run 'aws configure' first."
        log_info "Or set AWS credentials in environment variables."
        exit 1
    fi
    
    # Check if SSH key exists
    if [ ! -f "$KEY_PATH" ]; then
        log_error "SSH key not found at $KEY_PATH"
        log_info "Please ensure the private key exists or update KEY_PATH in this script."
        exit 1
    fi
    
    # Set correct permissions on SSH key
    chmod 600 "$KEY_PATH"
    
    # Check terraform version
    TERRAFORM_VERSION=$(terraform version -json 2>/dev/null | grep -o '"terraform_version": *"[^"]*"' | cut -d'"' -f4 || terraform version | head -1)
    log_info "Terraform version: $TERRAFORM_VERSION"
    
    log_info "All prerequisites met."
}

# Clean up orphaned models volumes before provisioning
cleanup_orphaned_volumes() {
    log_step "Checking for orphaned models volumes..."
    
    ORPHANED_VOLUMES=$(aws ec2 describe-volumes \
        --filters "Name=tag:Name,Values=*-models-volume" "Name=status,Values=available" \
        --query 'Volumes[*].VolumeId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$ORPHANED_VOLUMES" ]; then
        log_warn "Found orphaned models volumes:"
        for vol in $ORPHANED_VOLUMES; do
            log_warn "  - $vol"
        done
        
        read -p "$(echo -e ${YELLOW}Delete orphaned volumes before provisioning? [y/N]: ${NC})" -n1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for vol in $ORPHANED_VOLUMES; do
                log_info "Deleting $vol..."
                aws ec2 delete-volume --volume-id "$vol" && log_info "Deleted $vol" || log_error "Failed to delete $vol"
            done
        else
            log_warn "Orphaned volumes preserved. Terraform may fail if device names conflict."
        fi
    else
        log_info "No orphaned volumes found."
    fi
}

# Initialize Terraform (idempotent)
init_terraform() {
    log_step "Initializing Terraform..."
    cd "$TERRAFORM_DIR"
    
    # Check if already initialized
    if [ -d ".terraform" ] && [ -f ".terraform/environment" ]; then
        log_skip "Terraform already initialized"
    else
        log_info "Running terraform init..."
        terraform init -upgrade
    fi
    
    log_info "Terraform ready."
}

# Apply Terraform configuration (idempotent)
apply_terraform() {
    log_step "Applying Terraform configuration..."
    cd "$TERRAFORM_DIR"
    
    # Check if infrastructure already exists
    if terraform state list 2>/dev/null | grep -q "aws_instance"; then
        log_warn "Infrastructure already exists. Terraform will only apply changes."
    fi
    
    # Apply with optional tfvars file
    if [ -n "$TFVARS_FILE" ]; then
        log_info "Using tfvars file: $TFVARS_FILE"
        terraform apply -var-file="$TFVARS_FILE" -auto-approve
    else
        terraform apply -auto-approve
    fi
    
    log_info "Terraform apply completed."
}

# Get EC2 IP from Terraform outputs
get_ec2_ip() {
    cd "$TERRAFORM_DIR"
    EC2_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "")
    
    if [ -z "$EC2_IP" ]; then
        log_error "Failed to get EC2 IP from Terraform outputs"
        exit 1
    fi
    
    echo "$EC2_IP"
}

# Wait for EC2 instance to be ready (idempotent)
wait_for_instance() {
    local ip="$1"
    log_step "Waiting for EC2 instance to be ready..."
    
    # Check if already accessible
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ec2-user@"$ip" "echo 'ready'" &> /dev/null; then
        log_skip "EC2 instance already accessible"
        return 0
    fi
    
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ec2-user@"$ip" "echo 'ready'" &> /dev/null; then
            log_info "EC2 instance is ready!"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts - Waiting for SSH connection..."
        sleep 10
        ((attempt++))
    done
    
    log_error "Failed to connect to EC2 instance after $max_attempts attempts"
    return 1
}

# Clone repository on EC2 (idempotent)
clone_repository() {
    local ip="$1"
    log_step "Cloning repository on EC2 instance..."
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        # Check if repository already exists
        if [ -d "/opt/app/music/.git" ]; then
            echo "[SKIP] Repository already cloned, updating..."
            cd /opt/app/music
            git fetch origin
            git checkout main
            git pull origin main
        else
            echo "Cloning repository..."
            rm -rf /opt/app/music
            cd /opt/app
            git clone git@github.com:sinke237/music.git || {
                echo "Git clone with SSH failed, trying HTTPS..."
                git clone https://github.com/sinke237/music.git
            }
        fi
        
        echo "Repository ready at /opt/app/music"
ENDSSH
    
    log_info "Repository verified."
}

# Save EC2 IP to file for other scripts (idempotent)
save_ec2_ip() {
    local ip="$1"
    echo "$ip" > "$EC2_IP_FILE"
    log_info "EC2 IP saved to $EC2_IP_FILE"
}

# Main execution
main() {
    log_info "Starting infrastructure provisioning (Idempotent)..."
    log_info "========================================"
    
    # Step 1: Check prerequisites
    check_prerequisites
    
    # Step 2: Clean up orphaned volumes
    cleanup_orphaned_volumes
    
    # Step 3: Initialize Terraform (idempotent)
    init_terraform
    
    # Step 4: Apply Terraform configuration (idempotent)
    apply_terraform
    
    # Step 5: Get EC2 IP
    EC2_IP=$(get_ec2_ip)
    log_info "EC2 Public IP: $EC2_IP"
    
    # Step 6: Save IP for other scripts
    save_ec2_ip "$EC2_IP"
    
    # Step 7: Wait for instance to be ready (idempotent)
    wait_for_instance "$EC2_IP"
    
    # Step 8: Clone repository (idempotent)
    clone_repository "$EC2_IP"
    
    log_info "========================================"
    log_info "Infrastructure provisioning completed!"
    log_info ""
    log_info "EC2 Public IP: $EC2_IP"
    log_info "Web UI will be available at: http://$EC2_IP:3000"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Run: ./scripts/start-apps.sh"
    log_info "  2. Run: ./scripts/setup-ssl-dns.sh (for HTTPS)"
    log_info ""
    log_info "This script is idempotent - safe to run multiple times."
    log_info "To SSH into the instance:"
    log_info "  ssh -i $KEY_PATH ec2-user@$EC2_IP"
}

# Run main function
main "$@"