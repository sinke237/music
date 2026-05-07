#!/bin/bash
# =============================================================================
# Destroy Infrastructure Script (Idempotent)
# Destroys AWS resources but PRESERVES models by default
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$INFRA_DIR/terraform"

# Flags
DESTROY_MODELS=false

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --destroy-models|-m)
                DESTROY_MODELS=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --destroy-models, -m    Also destroy persistent models volume"
                echo "  --help, -h             Show this help message"
                echo ""
                echo "Default behavior:"
                echo "  - Destroys EC2 instance, VPC, Security Groups, etc."
                echo "  - PRESERVES models volume (/opt/models)"
                echo "  - Models can be reused on next deployment"
                echo ""
                echo "With --destroy-models:"
                echo "  - Destroys EVERYTHING including models"
                echo "  - Models will need to be re-downloaded (~50GB)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Run '$0 --help' for usage information"
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed."
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS CLI is not configured."
        exit 1
    fi
    
    log_info "Prerequisites met."
}

# Stop services on EC2 (optional)
stop_ec2_services() {
    log_step "Stopping services on EC2 (if running)..."
    
    if [ -f "$INFRA_DIR/.ec2_ip" ]; then
        EC2_IP=$(cat "$INFRA_DIR/.ec2_ip")
        KEY_PATH="$HOME/babaNaTrue/ema-practice.pem"
        
        if [ -f "$KEY_PATH" ]; then
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY_PATH" ec2-user@"$EC2_IP" << 'ENDSSH' || log_warn "Could not connect to EC2 to stop services"
                set -euo pipefail
                echo "Stopping all services..."
                sudo systemctl stop ace-step-ui || true
                sudo systemctl stop wan22 || true
                sudo systemctl stop ace-step-1.5 || true
                sudo systemctl stop nginx || true
                echo "Services stopped"
ENDSSH
        else
            log_warn "SSH key not found, skipping service stop"
        fi
    else
        log_warn "EC2 IP file not found, skipping service stop"
    fi
}

# Show what will be destroyed
show_destruction_plan() {
    log_warn "========================================"
    log_warn "DESTRUCTION PLAN"
    log_warn "========================================"
    log_warn ""
    
    if [ "$DESTROY_MODELS" = true ]; then
        log_warn "WILL DESTROY:"
        log_warn "  ✗ EC2 instance (p4de.24xlarge)"
        log_warn "  ✗ Elastic IP"
        log_warn "  ✗ VPC, Subnets, Security Groups"
        log_warn "  ✗ IAM roles and policies"
        log_warn "  ✗ Key pair"
        log_warn "  ✗ MODELS VOLUME (/opt/models) - ~50GB"
        log_warn ""
        log_warn "This action is NON-REVERSIBLE"
        log_warn "Models will need to be re-downloaded (~50GB, 1-2 hours)"
    else
        log_warn "WILL DESTROY:"
        log_warn "  ✗ EC2 instance (p4de.24xlarge)"
        log_warn "  ✗ Elastic IP"
        log_warn "  ✗ VPC, Subnets, Security Groups"
        log_warn "  ✗ IAM roles and policies"
        log_warn "  ✗ Key pair"
        log_warn ""
        log_warn "WILL PRESERVE:"
        log_warn "  ✓ MODELS VOLUME (/opt/models) - ~50GB"
        log_warn "  ✓ Models can be reused on next deployment"
        log_warn ""
        log_warn "To also destroy models, run: $0 --destroy-models"
    fi
    
    log_warn ""
}

# Destroy Terraform resources
destroy_terraform() {
    log_step "Destroying Terraform resources..."
    cd "$TERRAFORM_DIR"
    
    if [ "$DESTROY_MODELS" = true ]; then
        log_warn "Destroying models volume..."
        # Destroy everything including models volume
        terraform destroy -auto-approve
    else
        log_info "Preserving models volume..."
        # Destroy everything EXCEPT models volume
        # Remove models volume from state temporarily
        if terraform state list 2>/dev/null | grep -q "aws_ebs_volume.models"; then
            log_info "Removing models volume from Terraform state..."
            terraform state rm aws_ebs_volume.models 2>/dev/null || true
            terraform state rm aws_volume_attachment.models 2>/dev/null || true
        fi
        
        # Destroy everything else
        terraform destroy -auto-approve
    fi
    
    log_info "Terraform resources destroyed."
}

# Cleanup local files
cleanup_local_files() {
    log_step "Cleaning up local files..."
    
    # Remove EC2 IP file
    rm -f "$INFRA_DIR/.ec2_ip"
    
    # Models volume info
    if [ "$DESTROY_MODELS" = true ]; then
        log_info "Models volume destroyed."
    else
        log_info "Models volume preserved - can be reattached to new instance."
        log_info "Volume ID is stored in Terraform state (if using terraform state)."
    fi
    
    log_info "Local files cleaned up."
}

# Main execution
main() {
    # Parse arguments
    parse_args "$@"
    
    # Show destruction plan
    show_destruction_plan
    
    # Check prerequisites
    check_prerequisites
    
    # Stop services on EC2 (optional)
    stop_ec2_services
    
    # Destroy Terraform resources
    destroy_terraform
    
    # Cleanup local files
    cleanup_local_files
    
    log_info "========================================"
    log_info "Infrastructure destruction completed!"
    log_info "========================================"
    log_info ""
    
    if [ "$DESTROY_MODELS" = true ]; then
        log_info "All AWS resources destroyed including models."
        log_info "Next deployment will need to download models (~50GB)."
    else
        log_info "AWS infrastructure destroyed."
        log_info "Models volume preserved for reuse."
        log_info ""
        log_info "To reuse models on next deployment:"
        log_info "  1. Run: ./scripts/provision.sh"
        log_info "  2. Terraform will automatically reattach the models volume"
        log_info "  3. Models will be available at /opt/models"
        log_info ""
        log_info "To also destroy models volume:"
        log_info "  Run: $0 --destroy-models"
    fi
}

main "$@"