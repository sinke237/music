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
        log_warn "  × EC2 instance (g5.4xlarge)"
        log_warn "  × Elastic IP"
        log_warn "  × VPC, Subnets, Security Groups"
        log_warn "  × IAM roles and policies"
        log_warn "  × Key pair"
        log_warn "  × MODELS VOLUME (/opt/models) - ~50GB"
        log_warn ""
        log_warn "This action is NON-REVERSIBLE"
        log_warn "Models will need to be re-downloaded (~50GB, 1-2 hours)"
    else
        log_warn "WILL DESTROY:"
        log_warn "  × EC2 instance (g5.4xlarge)"
        log_warn "  × Elastic IP"
        log_warn "  × VPC, Subnets, Security Groups"
        log_warn "  × IAM roles and policies"
        log_warn "  × Key pair"
        log_warn ""
        log_warn "WILL PRESERVE:"
        log_warn "  ✓ MODELS VOLUME (/opt/models) - ~50GB"
        log_warn "  ✓ Models can be reused on next deployment"
        log_warn ""
        log_warn "To also destroy models, run: $0 --destroy-models"
    fi
    
    log_warn ""
}

# Ensure public key file exists for Terraform (Terraform file() function requires it)
ensure_public_key_exists() {
    PUBLIC_KEY_FILE="$INFRA_DIR/keys/ema-practice.pub"
    PRIVATE_KEY_FILE="$HOME/babaNaTrue/ema-practice.pem"
    
    if [ ! -f "$PUBLIC_KEY_FILE" ]; then
        log_step "Creating public key file for Terraform..."
        mkdir -p "$(dirname "$PUBLIC_KEY_FILE")"
        
        # If private key exists, extract public key from it
        if [ -f "$PRIVATE_KEY_FILE" ]; then
            ssh-keygen -y -f "$PRIVATE_KEY_FILE" > "$PUBLIC_KEY_FILE" 2>/dev/null
            log_info "Extracted public key from existing private key"
        else
            # Otherwise create a temporary placeholder (will be regenerated on provision)
            echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCplaceholder ema-practice" > "$PUBLIC_KEY_FILE"
            log_warn "Created placeholder public key (will be regenerated on provision)"
        fi
    fi
}

# Delete key pair from AWS and locally (ensures fresh key on next provision)
# Note: This runs AFTER Terraform destroy, so the public key file is still available
delete_key_pair() {
    log_step "Deleting key pair..."
    
    # Delete from AWS
    aws ec2 delete-key-pair --key-name ema-practice 2>/dev/null || true
    
    # Delete local private key
    rm -f "$HOME/babaNaTrue/ema-practice.pem"
    
    # Delete local public key
    rm -f "$INFRA_DIR/keys/ema-practice.pub"
    
    # Remove old/incorrect location if it exists
    rm -rf "$TERRAFORM_DIR/keys"
    
    log_info "Key pair deleted from AWS and locally."
}

# Reset tfvars to not import existing IAM resources
reset_tfvars() {
    log_step "Resetting terraform.tfvars..."
    
    if [ -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        sed -i 's/^import_existing_iam_role.*/import_existing_iam_role = false/' "$TERRAFORM_DIR/terraform.tfvars"
        sed -i 's/^import_existing_instance_profile.*/import_existing_instance_profile = false/' "$TERRAFORM_DIR/terraform.tfvars"
        log_info "Reset IAM import flags to false"
    fi
}

# Clean up orphaned IAM resources (roles/profiles that exist in AWS but not in Terraform state)
cleanup_orphaned_iam() {
    log_step "Checking for orphaned IAM resources..."
    
    PROJECT_NAME=$(grep -E '^project_name\s*=' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2 || echo "ema-practice")
    
    # Check and delete IAM role ifexists
    if aws iam get-role --role-name "${PROJECT_NAME}-ec2-role" 2>/dev/null; then
        log_warn "Found orphaned IAM role: ${PROJECT_NAME}-ec2-role"
        
        # Delete inline policies first
        for policy in $(aws iam list-role-policies --role-name "${PROJECT_NAME}-ec2-role" --output text 2>/dev/null); do
            log_info "Deleting policy: $policy"
            aws iam delete-role-policy --role-name "${PROJECT_NAME}-ec2-role" --policy-name "$policy" 2>/dev/null || true
        done
        
        # Detach managed policies
        for arn in $(aws iam list-attached-role-policies --role-name "${PROJECT_NAME}-ec2-role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
            log_info "Detaching policy: $arn"
            aws iam detach-role-policy --role-name "${PROJECT_NAME}-ec2-role" --policy-arn "$arn" 2>/dev/null || true
        done
        
        # Delete role
        aws iam delete-role --role-name "${PROJECT_NAME}-ec2-role" 2>/dev/null && log_info "Deleted IAM role" || log_warn "Could not delete IAM role"
    fi
    
    # Check and delete instance profile if exists
    if aws iam get-instance-profile --instance-profile-name "${PROJECT_NAME}-ec2-profile" 2>/dev/null; then
        log_warn "Found orphaned IAM instance profile: ${PROJECT_NAME}-ec2-profile"
        aws iam delete-instance-profile --instance-profile-name "${PROJECT_NAME}-ec2-profile" 2>/dev/null && log_info "Deleted IAM instance profile" || log_warn "Could not delete IAM instance profile"
    fi
}

# Delete orphaned models volumes by tag
delete_orphaned_models_volumes() {
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
        
        if [ "$DESTROY_MODELS" = true ]; then
            log_warn "Deleting orphaned models volumes..."
            for vol in $ORPHANED_VOLUMES; do
                aws ec2 delete-volume --volume-id "$vol" && log_info "Deleted $vol" || log_error "Failed to delete $vol"
            done
        else
            log_info "Preserving orphaned volumes (use --destroy-models to delete)"
        fi
    fi
}

# Force detach models volume from instance if attached
force_detach_models_volume() {
    if [ "$DESTROY_MODELS" = true ]; then
        log_step "Force detaching any attached models volumes..."
        
        ATTACHED_VOLUMES=$(aws ec2 describe-volumes \
            --filters "Name=tag:Name,Values=*-models-volume" "Name=status,Values=in-use" \
            --query 'Volumes[*].[VolumeId,Attachments[0].InstanceId]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$ATTACHED_VOLUMES" ]; then
            echo "$ATTACHED_VOLUMES" | while read vol_id instance_id; do
                if [ -n "$vol_id" ] && [ "$vol_id" != "None" ]; then
                    log_warn "Force detaching $vol_id from $instance_id..."
                    aws ec2 detach-volume --volume-id "$vol_id" --force 2>/dev/null || true
                    
                    log_info "Waiting for volume to become available..."
                    aws ec2 wait volume-available --volume-id "$vol_id" 2>/dev/null || true
                fi
            done
        fi
    fi
}

# Destroy Terraform resources
destroy_terraform() {
    log_step "Destroying Terraform resources..."
    cd "$TERRAFORM_DIR"
    
    if [ "$DESTROY_MODELS" = true ]; then
        log_warn "Destroying models volume..."
        
        force_detach_models_volume
        
        terraform destroy -auto-approve
        
        delete_orphaned_models_volumes
    else
        log_info "Preserving models volume..."
        if terraform state list 2>/dev/null | grep -q "aws_ebs_volume.models"; then
            log_info "Removing models volume from Terraform state..."
            terraform state rm aws_ebs_volume.models 2>/dev/null || true
            terraform state rm aws_volume_attachment.models 2>/dev/null || true
        fi
        
        terraform destroy -auto-approve
        
        delete_orphaned_models_volumes
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
    
    # Ensure public key file exists (Terraform file() requires it)
    ensure_public_key_exists
    
    # Reset tfvars to not import existing resources
    reset_tfvars
    
    # Destroy Terraform resources (run FIRST - needs public key file)
    destroy_terraform
    
    # Delete key pair from AWS (run AFTER Terraform destroy)
    delete_key_pair
    
    # Clean up orphaned IAM resources after Terraform destroy
    cleanup_orphaned_iam
    
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