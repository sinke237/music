#!/bin/bash
# =============================================================================
# Stop Applications Script
# Gracefully stops all services
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

# Stop all services
stop_services() {
    local ip="$1"
    log_step "Stopping all services..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        echo "Stopping services in correct order..."
        
        # Stop frontend first
        echo "Stopping ACE-Step UI..."
        sudo systemctl stop ace-step-ui || true
        sleep 2
        
        # Stop backends
        echo "Stopping Wan2.2..."
        sudo systemctl stop wan22 || true
        sleep 5
        
        echo "Stopping ACE-Step-1.5..."
        sudo systemctl stop ace-step-1.5 || true
        sleep 5
        
        # Stop nginx last
        echo "Stopping Nginx..."
        sudo systemctl stop nginx || true
        
        echo ""
        echo "Service Status:"
        echo "----------------------------------------"
        sudo systemctl status ace-step-1.5 --no-pager || true
        sudo systemctl status wan22 --no-pager || true
        sudo systemctl status ace-step-ui --no-pager || true
        sudo systemctl status nginx --no-pager || true
        
        echo ""
        echo "Checking for remaining GPU processes..."
        nvidia-smi || echo "No GPU processes running"
        
        echo ""
        echo "All services stopped successfully"
ENDSSH
}

# Main execution
main() {
    log_info "Stopping all applications..."
    log_info "========================================"
    
    EC2_IP=$(get_ec2_ip)
    log_info "Using EC2 IP: $EC2_IP"
    
    stop_services "$EC2_IP"
    
    log_info "========================================"
    log_info "All applications stopped successfully!"
    log_info ""
    log_info "To restart, run: ./scripts/start-apps.sh"
}

main "$@"