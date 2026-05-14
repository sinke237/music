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

# Generate SSH key pair (both locally and for AWS via Terraform)
generate_ssh_key() {
    log_step "Generating SSH key pair..."
    
    KEY_DIR="$HOME/babaNaTrue"
    KEY_PATH="$KEY_DIR/ema-practice.pem"
    KEYS_DIR="$INFRA_DIR/keys"
    PUBLIC_KEY_PATH="$KEYS_DIR/ema-practice.pub"
    
    # Create key directory if it doesn't exist
    mkdir -p "$KEY_DIR"
    mkdir -p "$KEYS_DIR"
    
    # Generate private key if it doesn't exist
    if [ ! -f "$KEY_PATH" ]; then
        log_info "Creating new SSH key pair at $KEY_PATH..."
        ssh-keygen -t rsa -b 2048 -f "$KEY_PATH" -N "" -C "ema-practice"
    else
        log_info "SSH key exists at $KEY_PATH"
    fi
    
    # Set correct permissions (400 is required for SSH private keys)
    chmod 400 "$KEY_PATH"
    
    # Generate public key for Terraform (always regenerate to ensure sync)
    ssh-keygen -y -f "$KEY_PATH" > "$PUBLIC_KEY_PATH" 2>/dev/null
    
    # Ensure file is flushed to disk
    sync
    
    # Verify the file was written correctly by reading it back
    if [ ! -f "$PUBLIC_KEY_PATH" ]; then
        log_error "Failed to create public key file"
        exit 1
    fi
    
    # Verify public key matches private key
    # Note: AWS uses PKCS8 DER format for fingerprints, not OpenSSH format
    LOCAL_DER_FP=$(ssh-keygen -e -f "$KEY_PATH" -m PKCS8 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -md5 -c 2>/dev/null | awk '{print $NF}')
    PUB_DER_FP=$(ssh-keygen -e -f "$PUBLIC_KEY_PATH" -m PKCS8 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -md5 -c 2>/dev/null | awk '{print $NF}')
    
    if [ "$LOCAL_DER_FP" != "$PUB_DER_FP" ]; then
        log_error "Public key file does not match private key!"
        log_error "  Private key fingerprint (DER): $LOCAL_DER_FP"
        log_error "  Public key fingerprint (DER):   $PUB_DER_FP"
        exit 1
    fi
    
    log_info "Public key created at $PUBLIC_KEY_PATH"
    log_info "Key fingerprint (AWS format): $LOCAL_DER_FP"
}

# Delete existing key pair from AWS (ensures fresh key)
delete_key_pair() {
    log_step "Ensuring clean key pair state..."
    
    # Delete from AWS
    aws ec2 delete-key-pair --key-name ema-practice 2>/dev/null || true
    
    # Delete local private key (so provision creates fresh)
    rm -f "$HOME/babaNaTrue/ema-practice.pem"
    rm -f "$HOME/babaNaTrue/ema-practice.pem.pub"
    
    # Delete local public key
    rm -f "$INFRA_DIR/keys/ema-practice.pub"
    
    # Remove old/incorrect location
    rm -rf "$TERRAFORM_DIR/keys"
    
    # Remove from Terraform state if exists
    cd "$TERRAFORM_DIR"
    terraform state rm 'aws_key_pair.deployer[0]' 2>/dev/null || true
    cd - > /dev/null
    
    log_info "Key pair state cleaned."
}

# Import existing IAM resources into Terraform state if they exist in AWS
import_iam_resources() {
    log_step "Checking for existing IAM resources..."
    cd "$TERRAFORM_DIR"
    
    # Get project name from tfvars or use default
    PROJECT_NAME=$(grep -E '^project_name\s*=' terraform.tfvars 2>/dev/null | cut -d'"' -f2 || grep -E '^project_name\s*=' terraform.tfvars | cut -d'=' -f2 | tr -d ' "')
    PROJECT_NAME="${PROJECT_NAME:-ema-practice}"
    
    # Check if IAM role exists in AWS
    if aws iam get-role --role-name "${PROJECT_NAME}-ec2-role" 2>/dev/null; then
        log_warn "IAM role ${PROJECT_NAME}-ec2-role already exists in AWS"
        
        # Check if it's already in Terraform state
        if ! terraform state list 2>/dev/null | grep -q "aws_iam_role.ec2_role\[0\]"; then
            log_info "Importing IAM role into Terraform state..."
            terraform import "aws_iam_role.ec2_role[0]" "${PROJECT_NAME}-ec2-role" 2>/dev/null || true
        fi
        
        # Update tfvars to use existing role
        sed -i 's/^import_existing_iam_role.*/import_existing_iam_role = true/' terraform.tfvars
        log_info "Updated import_existing_iam_role = true in terraform.tfvars"
    fi
    
    # Check if instance profile exists in AWS
    if aws iam get-instance-profile --instance-profile-name "${PROJECT_NAME}-ec2-profile" 2>/dev/null; then
        log_warn "IAM instance profile ${PROJECT_NAME}-ec2-profile already exists in AWS"
        
        # Check if it's already in Terraform state
        if ! terraform state list 2>/dev/null | grep -q "aws_iam_instance_profile.ec2_profile\[0\]"; then
            log_info "Importing IAM instance profile into Terraform state..."
            terraform import "aws_iam_instance_profile.ec2_profile[0]" "${PROJECT_NAME}-ec2-profile" 2>/dev/null || true
        fi
        
        # Update tfvars to use existing profile
        sed -i 's/^import_existing_instance_profile.*/import_existing_instance_profile = true/' terraform.tfvars
        log_info "Updated import_existing_instance_profile = true in terraform.tfvars"
    fi
    
    cd - > /dev/null
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

# Verify key fingerprints match
verify_key_fingerprint() {
    log_step "Verifying key fingerprints match..."
    
    # AWS computes fingerprints using MD5 of the DER-encoded public key (PKCS8 format)
    # This is different from ssh-keygen which uses OpenSSH format
    # We need to compute the fingerprint the same way AWS does
    
    LOCAL_FP=$(ssh-keygen -e -f "$KEY_PATH" -m PKCS8 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -md5 -c 2>/dev/null | awk '{print $NF}')
    
    # Get AWS key fingerprint
    AWS_FP=$(aws ec2 describe-key-pairs --key-names ema-practice --query 'KeyPairs[0].KeyFingerprint' --output text 2>/dev/null)
    
    if [ "$LOCAL_FP" = "$AWS_FP" ]; then
        log_info "Key fingerprints match - SSH authentication will work"
    else
        log_error "Key fingerprints DO NOT match!"
        log_error "  Local (DER MD5): $LOCAL_FP"
        log_error "  AWS:             $AWS_FP"
        log_error ""
        log_error "SSH authentication will fail. Run destroy.sh and provision.sh again."
        exit 1
    fi
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
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ubuntu@"$ip" "echo 'ready'" &> /dev/null; then
        log_skip "EC2 instance already accessible"
        return 0
    fi
    
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ubuntu@"$ip" "echo'ready'" &> /dev/null; then
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
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
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
    
    # Step 2: Delete existing key pair (ensures fresh key) - MUST run before generate_ssh_key
    delete_key_pair
    
    # Step 3: Generate SSH key pair (after deletion ensures fresh keys)
    generate_ssh_key
    
    # Step 4: Clean up orphaned volumes
    cleanup_orphaned_volumes
    
    # Step 5: Initialize Terraform (idempotent)
    init_terraform
    
    # Step 6: Import existing IAM resources into state
    import_iam_resources
    
    # Step 7: Apply Terraform configuration (idempotent)
    apply_terraform
    
    # Step 8: Verify key fingerprints match
    verify_key_fingerprint
    
    # Step 9: Get EC2 IP
    EC2_IP=$(get_ec2_ip)
    log_info "EC2 Public IP: $EC2_IP"
    
    # Step 10: Save IP for other scripts
    save_ec2_ip "$EC2_IP"
    
    # Step 11: Clone repository (idempotent) - run manually after instance is ready
    # clone_repository "$EC2_IP"
    
    log_info "========================================"
    log_info "Infrastructure provisioning completed!"
    log_info ""
    log_info "EC2 Public IP: $EC2_IP"
    log_info ""
    log_info "Wait for instance to be ready on AWS, then run:"
    log_info "  ./scripts/start-apps.sh"
    log_info ""
    log_info "To SSH into the instance:"
    log_info "  ssh -i $KEY_PATH ubuntu@$EC2_IP"
}

# Run main function
main "$@"