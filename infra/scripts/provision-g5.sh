#!/bin/bash
# =============================================================================
# Infrastructure Provisioning Script - Multi-Instance g5.48xlarge Mode
# Deploys multiple GPU instances for distributed ACE-Step and Wan2.2
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
TFVARS_FILE="terraform-g5.tfvars"

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
    
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed. Please install it first."
        log_info "Download from: https://www.terraform.io/downloads"
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi
    
    if [ ! -f "$KEY_PATH" ]; then
        log_error "SSH key not found at $KEY_PATH"
        exit 1
    fi
    
    chmod 600 "$KEY_PATH"
    
    log_info "All prerequisites met."
}

# Initialize Terraform
init_terraform() {
    log_step "Initializing Terraform..."
    cd "$TERRAFORM_DIR"
    
    if [ -d ".terraform" ] && [ -f ".terraform/environment" ]; then
        log_skip "Terraform already initialized"
    else
        log_info "Running terraform init..."
        terraform init -upgrade
    fi
    
    log_info "Terraform ready."
}

# Apply Terraform configuration with g5 tfvars
apply_terraform() {
    log_step "Applying Terraform configuration (g5 multi-instance mode)..."
    cd "$TERRAFORM_DIR"
    
    if terraform state list 2>/dev/null | grep -q "aws_instance"; then
        log_warn "Infrastructure already exists. Terraform will only apply changes."
    fi
    
    terraform apply -var-file="$TFVARS_FILE" -auto-approve
    
    log_info "Terraform apply completed."
}

# Get instance IPs from Terraform outputs
get_instance_ips() {
    cd "$TERRAFORM_DIR"
    
    # Get ACE instance IPs
    ACE_IPS=$(terraform output -json ace_instance_public_ips 2>/dev/null | jq -r '.[]' || echo "")
    WAN_IPS=$(terraform output -json wan_instance_public_ips 2>/dev/null | jq -r '.[]' || echo "")
    
    if [ -z "$ACE_IPS" ]; then
        log_error "Failed to get ACE instance IPs from Terraform outputs"
        exit 1
    fi
    
    # Get primary ACE IP (first one)
    PRIMARY_ACE_IP=$(echo "$ACE_IPS" | head -1)
    
    echo "ACE_IPS:$ACE_IPS"
    echo "WAN_IPS:$WAN_IPS"
    echo "PRIMARY:$PRIMARY_ACE_IP"
}

# Wait for EC2 instance to be ready
wait_for_instance() {
    local ip="$1"
    local name="$2"
    log_step "Waiting for $name instance to be ready ($ip)..."
    
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ec2-user@"$ip" "echo 'ready'" &> /dev/null; then
        log_skip "$name instance already accessible"
        return 0
    fi
    
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ec2-user@"$ip" "echo 'ready'" &> /dev/null; then
            log_info "$name instance is ready!"
            return 0
        fi
        
        log_info "[$name] Attempt $attempt/$max_attempts - Waiting for SSH connection..."
        sleep 10
        ((attempt++))
    done
    
    log_error "Failed to connect to $name instance after $max_attempts attempts"
    return 1
}

# Clone repository on instances
clone_repository() {
    local ip="$1"
    local name="$2"
    log_step "Cloning repository on $name instance..."
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
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
            git clone https://github.com/sinke237/music.git || {
                echo "Git clone failed"
                exit 1
            }
        fi
        
        echo "Repository ready at /opt/app/music"
ENDSSH
    
    log_info "Repository verified on $name."
}

# Save instance IPs to file
save_instance_ips() {
    local ace_ips="$1"
    local wan_ips="$2"
    local primary="$3"
    
    cat > "$EC2_IP_FILE" << EOF
# Infrastructure Instance IPs (generated by provision-g5.sh)
# Generated: $(date)

PRIMARY_ACE_IP=$primary

ACE_INSTANCES=(
$(echo "$ace_ips" | sed 's/^/  /')
)

WAN_INSTANCES=(
$(echo "$wan_ips" | sed 's/^/  /')
)
EOF
    
    log_info "Instance IPs saved to $EC2_IP_FILE"
}

# Main execution
main() {
    log_info "Starting multi-instance (g5.48xlarge) provisioning..."
    log_info "============================================"
    
    check_prerequisites
    init_terraform
    apply_terraform
    
    # Get all instance IPs
    IPS=$(get_instance_ips)
    ACE_IPS=$(echo "$IPS" | grep "ACE_IPS:" | cut -d: -f2)
    WAN_IPS=$(echo "$IPS" | grep "WAN_IPS:" | cut -d: -f2)
    PRIMARY_ACE_IP=$(echo "$IPS" | grep "PRIMARY:" | cut -d: -f2)
    
    log_info "Primary ACE IP: $PRIMARY_ACE_IP"
    log_info "ACE Instances: $ACE_IPS"
    log_info "WAN Instances: $WAN_IPS"
    
    # Save IPs
    save_instance_ips "$ACE_IPS" "$WAN_IPS" "$PRIMARY_ACE_IP"
    
    # Wait for primary ACE instance
    wait_for_instance "$PRIMARY_ACE_IP" "Primary ACE"
    
    # Clone repository on primary ACE
    clone_repository "$PRIMARY_ACE_IP" "Primary ACE"
    
    # Wait for WAN instances and clone repos
    if [ -n "$WAN_IPS" ]; then
        for wan_ip in $WAN_IPS; do
            wait_for_instance "$wan_ip" "WAN" &
        done
        wait
        
        for wan_ip in $WAN_IPS; do
            clone_repository "$wan_ip" "WAN ($wan_ip)" &
        done
        wait
    fi
    
    log_info "============================================"
    log_info "Multi-instance provisioning completed!"
    log_info ""
    log_info "Primary ACE IP: $PRIMARY_ACE_IP"
    log_info "ACE Instances: $(echo "$ACE_IPS" | wc -w) total"
    log_info "WAN Instances: $(echo "$WAN_IPS" | wc -w) total"
    log_info ""
    log_info "Web UI: http://$PRIMARY_ACE_IP:3000"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Setup NFS for models sharing: ./scripts/setup-nfs.sh"
    log_info "  2. Run: ./scripts/start-apps-multi.sh"
    log_info "  3. Configure DNS to point to: $PRIMARY_ACE_IP"
    log_info ""
    log_info "SSH into primary ACE instance:"
    log_info "  ssh -i $KEY_PATH ec2-user@$PRIMARY_ACE_IP"
}

# Run main function
main "$@"