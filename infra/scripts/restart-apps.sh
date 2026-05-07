#!/bin/bash
# =============================================================================
# Restart Applications Script
# Restarts services after updates
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
KEY_PATH="$HOME/babaNaTrue/ema-practice.pem"
EC2_IP_FILE="$INFRA_DIR/.ec2_ip"

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get EC2 IP
get_ec2_ip() {
    if [ ! -f "$EC2_IP_FILE" ]; then
        log_error "EC2 IP file not found at $EC2_IP_FILE"
        log_error "Please run provision.sh first."
        exit 1
    fi
    cat "$EC2_IP_FILE"
}

# Restart all services
restart_services() {
    local ip="$1"
    log_step "Restarting all services..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        echo "Restarting services..."
        
        # Stop all services first
        echo "Stopping services..."
        sudo systemctl stop ace-step-ui || true
        sudo systemctl stop wan22 || true
        sudo systemctl stop ace-step-1.5 || true
        sudo systemctl stop nginx || true
        
        sleep 5
        
        # Start in dependency orderecho "Starting ACE-Step-1.5 (GPU 0)..."
        sudo systemctl start ace-step-1.5
        sleep 60
        
        echo "Starting Wan2.2 (GPUs 1-7)..."
        sudo systemctl start wan22
        sleep 30
        
        echo "Starting ACE-Step UI..."
        sudo systemctl start ace-step-ui
        sleep 5
        
        echo "Starting Nginx..."
        sudo systemctl start nginx
        
        echo ""
        echo "Service Status:"
        echo "----------------------------------------"
        sudo systemctl status ace-step-1.5 --no-pager || true
        sudo systemctl status wan22 --no-pager || true
        sudo systemctl status ace-step-ui --no-pager || true
        sudo systemctl status nginx --no-pager || true
        
        echo ""
        echo "GPU Status:"
        echo "----------------------------------------"
        nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv || echo "Could not query GPU status"
        
        echo ""
        echo "All services restarted successfully!"
ENDSSH
}

# Main execution
main() {
    log_info "Restarting all applications..."
    log_info "========================================"
    
    EC2_IP=$(get_ec2_ip)
    log_info "Using EC2 IP: $EC2_IP"
    
    restart_services "$EC2_IP"
    
    log_info "========================================"
    log_info "All applications restarted successfully!"
    log_info ""
    log_info "Services are running:"
    log_info "  - ACE-Step-1.5: http://$EC2_IP:8001"
    log_info "  - Wan2.2: http://$EC2_IP:8080"
    log_info "  - ACE-Step UI: http://$EC2_IP:3000"
    log_info "  - Nginx Gateway: http://$EC2_IP:80"
}

main "$@"