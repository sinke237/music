#!/bin/bash
# =============================================================================
# Update Code Script
# Pulls latest code and updates dependencies
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

# Update code
update_code() {
    local ip="$1"
    log_step "Updating code on EC2..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        cd /opt/app/music
        
        echo "Current branch: $(git branch --show-current)"
        echo "Current commit: $(git log -1 --oneline)"
        
        echo "Stashing any local changes..."
        git stash || true
        
        echo "Fetching latest changes..."
        git fetch origin
        
        echo "Checking out main branch..."
        git checkout main
        
        echo "Pulling latest code..."
        git pull origin main
        
        echo "Restoring stashed changes..."
        git stash pop || true
        
        echo "Code updated successfully"
        echo "New commit: $(git log -1 --oneline)"
ENDSSH
}

# Update dependencies
update_dependencies() {
    local ip="$1"
    log_step "Updating dependencies..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        echo "Updating ACE-Step-1.5 dependencies..."
        cd /opt/app/music/ACE-Step-1.5
        source .venv/bin/activate || {
            echo "Virtual environment not found, creating..."
            uv venv
            source .venv/bin/activate
        }
        uv sync --upgrade
        
        echo "Updating Wan2.2 dependencies..."
        cd /opt/app/music/Wan2.2
        source .venv/bin/activate || {
            echo "Virtual environment not found, creating..."
            python3.11 -m venv .venv
            source .venv/bin/activate
        }
        pip install -r requirements.txt --upgrade
        pip install fastapi uvicorn python-multipart
        
        echo "Updating ace-step-ui dependencies..."
        cd /opt/app/music/ace-step-ui
        npm install
        
        echo "All dependencies updated successfully"
ENDSSH
}

# Main execution
main() {
    log_info "Updating code and dependencies..."
    log_info "========================================"
    
    EC2_IP=$(get_ec2_ip)
    log_info "Using EC2 IP: $EC2_IP"
    
    # Step 1: Stop services before update
    log_step "Stopping services before update..."    log_warn "This will stop all running services temporarily"
    
    "$SCRIPT_DIR/stop-apps.sh"
    
    # Step 2: Update code
    update_code "$EC2_IP"
    
    # Step 3: Update dependencies
    update_dependencies "$EC2_IP"
    
    log_info "========================================"
    log_info "Code updated successfully!"
    log_info ""
    log_info "Changes will take effect after restarting services."
    log_info "To restart: ./scripts/restart-apps.sh"
}

main "$@"