#!/bin/bash
# =============================================================================
# Application Startup Script (Idempotent)
# Installs dependencies and starts all services
# Safe to run multiple times
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
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1 Already installed/configured"; }

# Get EC2 IP
get_ec2_ip() {
    if [ ! -f "$EC2_IP_FILE" ]; then
        log_error "EC2 IP file not found at $EC2_IP_FILE"
        log_error "Please run provision.sh first."
        exit 1
    fi
    cat "$EC2_IP_FILE"
}

# Install system dependencies (idempotent)
install_system_dependencies() {
    local ip="$1"
    log_step "Checking system dependencies..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        echo "Updating system packages (if needed)..."
        sudo yum update -y 2>/dev/null || echo "[SKIP] Already up to date"
        
        # Check and install Python 3.11 (idempotent)
        if ! python3.11 --version &>/dev/null; then
            echo "Installing Python 3.11..."
            sudo yum install -y python3.11 python3.11-devel python3.11-pip
        else
            echo "[SKIP] Python 3.11 already installed: $(python3.11 --version)"
        fi
        
        # Check and install Node.js 18 (idempotent)
        if ! node --version 2>/dev/null | grep -q "v18"; then
            echo "Installing Node.js 18..."
            curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
            sudo yum install -y nodejs
        else
            echo "[SKIP] Node.js already installed: $(node --version)"
        fi
        
        # Check and install build tools (idempotent)
        if ! rpm -q "gcc" &>/dev/null; then
            echo "Installing build tools..."
            sudo yum groupinstall -y "Development Tools"
            sudo yum install -y git wget curl ffmpeg ffmpeg-devel
        else
            echo "[SKIP] Build tools already installed"
        fi
        
        # Check and install nginx (idempotent)
        if ! rpm -q "nginx" &>/dev/null; then
            echo "Installing nginx..."
            sudo yum install -y nginx
            sudo systemctl enable nginx
        else
            echo "[SKIP] Nginx already installed"
        fi
        
        # Check and install uv (idempotent)
        if ! command -v uv &>/dev/null &&[ ! -f "$HOME/.local/bin/uv" ]; then
            echo "Installing uv package manager..."
            curl -LsSf https://astral.sh/uv/install.sh | sh
            export PATH="$HOME/.local/bin:$PATH"
        else
            echo "[SKIP] uv already installed"
        fi
        
        # GPU check (informational)
        echo "Checking NVIDIA GPU..."
        nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader || echo "Warning: nvidia-smi not available"
        
        echo "System dependencies verified"
ENDSSH
}

# Setup ACE-Step-1.5 (idempotent)
setup_ace_step() {
    local ip="$1"
    log_step "Setting up ACE-Step-1.5..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        cd /opt/app/music/ACE-Step-1.5
        
        # Ensure models directory exists and is linked
        mkdir -p /opt/models/acestep
        if [ ! -L "checkpoints" ]; then
            if [ -d "checkpoints" ] && [ "$(ls -A checkpoints 2>/dev/null)" ]; then
                # Existing checkpoints found, move to persistent location
                echo "Moving existing checkpoints to persistent storage..."
                mv checkpoints/* /opt/models/acestep/ 2>/dev/null || true
            fi
            rm -rf checkpoints
            ln -s /opt/models/acestep checkpoints
            echo "Linked checkpoints to persistent storage"
        fi
        
        # Check if virtual environment exists
        if [ ! -d ".venv" ]; then
            echo "Creating virtual environment..."
            uv venv
        else
            echo "[SKIP] Virtual environment already exists"
        fi
        
        source .venv/bin/activate
        
        # Check if dependencies are installed
        if ! python -c "import acestep" 2>/dev/null; then
            echo "Installing dependencies..."
            uv sync
        else
            echo "[SKIP] Dependencies already installed"
        fi
        
        # Check if models are downloaded (use persistent storage)
        if [ ! -d "/opt/models/acestep/acestep-v15-xl-sft" ] || [ -z "$(ls -A /opt/models/acestep/acestep-v15-xl-sft 2>/dev/null)" ]; then
            echo "Downloading ACE-Step models to persistent storage..."
            echo "This may take 30-60 minutes on first run..."
            
            # Download all models (best quality)
            export ACESTEP_CHECKPOINTS_DIR=/opt/models/acestep
            uv run acestep-download --all --download-source auto || {
                echo "Model download failed. Models will be downloaded on first run."
                echo "You can manually download with: ACESTEP_CHECKPOINTS_DIR=/opt/models/acestep uv run acestep-download --all"
            }
        else
            echo "[SKIP] ACE-Step models already downloaded"
            echo "Models available: $(ls /opt/models/acestep/)"
        fi
        
        # Set checkpoint directory environment
        export ACESTEP_CHECKPOINTS_DIR=/opt/models/acestep
        
        echo "ACE-Step-1.5 setup verified"
        echo "Models location: /opt/models/acestep (persistent)"
ENDSSH
}

# Setup Wan2.2 (idempotent)
setup_wan22() {
    local ip="$1"
    log_step "Setting up Wan2.2..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        cd /opt/app/music/Wan2.2
        
        # Check if virtual environment exists
        if [ ! -d ".venv" ]; then
            echo "Creating virtual environment..."
            python3.11 -m venv .venv
        else
            echo "[SKIP] Virtual environment already exists"
        fi
        
        source .venv/bin/activate
        
        # Check if dependencies are installed
        if ! python -c "import torch" 2>/dev/null; then
            echo "Installing dependencies..."
            pip install --upgrade pip
            pip install -r requirements.txt
            pip install fastapi uvicorn python-multipart
        else
            echo "[SKIP] Dependencies already installed"
        fi
        
        # Check if models are downloaded (use persistent storage)
        mkdir -p /opt/models
        
        if [ ! -d "/opt/models/Wan2.2-T2V-A14B" ] || [ -z "$(ls -A /opt/models/Wan2.2-T2V-A14B 2>/dev/null)" ]; then
            echo "Downloading Wan2.2-T2V-A14B model to persistent storage..."
            echo "This is a 40GB+ download and may take 1-2 hours..."
            
            pip install "huggingface_hub[cli]" 2>/dev/null || true
            
            huggingface-cli download Wan-AI/Wan2.2-T2V-A14B --local-dir /opt/models/Wan2.2-T2V-A14B || {
                echo "Model download failed. You can manually download with:"
                echo "  huggingface-cli download Wan-AI/Wan2.2-T2V-A14B --local-dir /opt/models/Wan2.2-T2V-A14B"
            }
        else
            echo "[SKIP] Wan2.2 models already downloaded"
            echo "Model size: $(du -sh /opt/models/Wan2.2-T2V-A14B | cut -f1)"
        fi
        
        echo "Wan2.2 setup verified"
        echo "Models location: /opt/models/Wan2.2-T2V-A14B (persistent)"
ENDSSH
}

# Setup ace-step-ui (idempotent)
setup_ace_step_ui() {
    local ip="$1"
    log_step "Setting up ace-step-ui..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        cd /opt/app/music/ace-step-ui
        
        # Check if node_modules exists
        if [ ! -d "node_modules" ]; then
            echo "Installing frontend dependencies..."
            npm install
        else
            echo "[SKIP] Frontend dependencies already installed"
        fi
        
        # Check if server node_modules exists
        if [ ! -d "server/node_modules" ]; then
            echo "Installing backend dependencies..."
            cd server
            npm install
            cd ..
        else
            echo "[SKIP] Backend dependencies already installed"
        fi
        
        # Check if .env exists
        if [ ! -f "server/.env" ]; then
            echo "Copying environment file..."
            cp server/.env.example server/.env 2>/dev/null || echo "[SKIP] No .env.example found"
        else
            echo "[SKIP] Environment file already exists"
        fi
        
        echo "ace-step-ui setup verified"
ENDSSH
}

# Configure Nginx (idempotent)
configure_nginx() {
    local ip="$1"
    log_step "Configuring Nginx..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        NGINX_CONF="/etc/nginx/nginx.conf"
        SOURCE_CONF="/opt/app/music/infra/configs/nginx/nginx.conf"
        
        # Check if nginx config is already up to date
        if [ -f "$NGINX_CONF" ] && cmp -s "$SOURCE_CONF" "$NGINX_CONF"; then
            echo "[SKIP] Nginx configuration already up to date"
        else
            echo "Installing nginx config..."
            sudo cp "$SOURCE_CONF" "$NGINX_CONF"
        fi
        
        # Ensure log directory exists
        if [ ! -d "/var/log/nginx" ]; then
            sudo mkdir -p /var/log/nginx
            sudo chown nginx:nginx /var/log/nginx 2>/dev/null || true
        fi
        
        # Test and reload nginx
        echo "Testing nginx config..."
        if sudo nginx -t; then
            echo "Nginx configuration is valid"
        else
            echo "ERROR: Nginx configuration is invalid"
            exit 1
        fi
        
        echo "Nginx configured"
ENDSSH
}

# Copy systemd service files (idempotent)
copy_systemd_services() {
    local ip="$1"
    log_step "Copying systemd service files..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        SERVICES_DIR="/opt/app/music/infra/configs/systemd"
        SYSTEM_DIR="/etc/systemd/system"
        
        # Check if services are already configured and up to date
        NEED_RELOAD=0
        
        for service in ace-step-1.5.service wan22.service ace-step-ui.service nginx.service; do
            if [ -f "$SYSTEM_DIR/$service" ]; then
                if cmp -s "$SERVICES_DIR/$service" "$SYSTEM_DIR/$service"; then
                    echo "[SKIP] $service already up to date"
                else
                    echo "Updating $service..."
                    sudo cp "$SERVICES_DIR/$service" "$SYSTEM_DIR/$service"
                    NEED_RELOAD=1
                fi
            else
                echo "Installing $service..."
                sudo cp "$SERVICES_DIR/$service" "$SYSTEM_DIR/$service"
                NEED_RELOAD=1
            fi
        done
        
        # Copy environment files
        mkdir -p /opt/app/music/ACE-Step-1.5
        mkdir -p /opt/app/music/Wan2.2
        mkdir -p /opt/app/music/ace-step-ui/server
        
        for env_file in /opt/app/music/infra/configs/env/*.env; do
            service_name=$(basename "$env_file" .env)
            target_dir=""
            
            case "$service_name" in
                "ace-step-1.5") target_dir="/opt/app/music/ACE-Step-1.5" ;;
                "wan22") target_dir="/opt/app/music/Wan2.2" ;;
                "ace-step-ui") target_dir="/opt/app/music/ace-step-ui/server" ;;
            esac
            
            if [ -n "$target_dir" ]; then
                if [ -f "$target_dir/.env" ]; then
                    echo "[SKIP] $service_name/.env already exists"
                else
                    echo "Copying $service_name/.env..."
                    sudo cp "$env_file" "$target_dir/.env"
                fi
            fi
        done
        
        # Reload systemd if needed
        if [ "$NEED_RELOAD" -eq 1 ]; then
            echo "Reloading systemd daemon..."
            sudo systemctl daemon-reload
        else
            echo "[SKIP] Systemd daemon already up to date"
        fi
        
        echo "Systemd services verified"
ENDSSH
}

# Start all services (idempotent)
start_services() {
    local ip="$1"
    log_step "Starting all services..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        # Function to start service if not running
        start_if_not_running() {
            local service="$1"
            local delay="$2"
            
            if sudo systemctl is-active --quiet "$service"; then
                echo "[SKIP] $service already running"
            else
                echo "Starting $service..."
                sudo systemctl start "$service"
                sleep "$delay"
            fi
        }
        
        # Enable services (idempotent)
        echo "Enabling services..."
        sudo systemctl enable ace-step-1.5 2>/dev/null || true
        sudo systemctl enable wan22 2>/dev/null || true
        sudo systemctl enable ace-step-ui 2>/dev/null || true
        sudo systemctl enable nginx 2>/dev/null || true
        
        # Start services in dependency order
        echo "Starting services in dependency order..."
        
        start_if_not_running "ace-step-1.5" 30
        start_if_not_running "wan22" 15
        start_if_not_running "ace-step-ui" 5
        start_if_not_running "nginx" 2
        
        # Show status
        echo ""
        echo "Service Status:"
        echo "----------------------------------------"
        sudo systemctl status ace-step-1.5 --no-pager || true
        echo ""
        sudo systemctl status wan22 --no-pager || true
        echo ""
        sudo systemctl status ace-step-ui --no-pager || true
        echo ""
        sudo systemctl status nginx --no-pager || true
        
        echo ""
        echo "GPU Status:"
        echo "----------------------------------------"
        nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv || echo "Could not query GPU status"
        
        echo ""
        echo "All services running!"
ENDSSH
}

# Main execution
main() {
    log_info "Starting application deployment (Idempotent)..."
    log_info "========================================"
    
    # Get EC2 IP
    EC2_IP=$(get_ec2_ip)
    log_info "Using EC2 IP: $EC2_IP"
    
    # Step 1: Install system dependencies (idempotent)
    install_system_dependencies "$EC2_IP"
    
    # Step 2: Setup ACE-Step-1.5 (idempotent)
    setup_ace_step "$EC2_IP"
    
    # Step 3: Setup Wan2.2 (idempotent)
    setup_wan22 "$EC2_IP"
    
    # Step 4: Setup ace-step-ui (idempotent)
    setup_ace_step_ui "$EC2_IP"
    
    # Step 5: Configure Nginx (idempotent)
    configure_nginx "$EC2_IP"
    
    # Step 6: Copy systemd service files (idempotent)
    copy_systemd_services "$EC2_IP"
    
    # Step 7: Start all services (idempotent)
    start_services "$EC2_IP"
    
    log_info "========================================"
    log_info "Application deployment completed!"
    log_info ""
    log_info "Services are running:"
    log_info "  - ACE-Step-1.5: http://$EC2_IP:8001 (GPU 0)"
    log_info "  - Wan2.2: http://$EC2_IP:8080 (GPUs 1-7)"
    log_info "  - ACE-Step UI: http://$EC2_IP:3000"
    log_info "  - Nginx Gateway: http://$EC2_IP:80"
    log_info ""
    log_info "GPU Allocation:"
    log_info "  - GPU 0: ACE-Step-1.5 (80GB)"
    log_info "  - GPUs 1-7: Wan2.2 (560GB total)"
    log_info ""
    log_info "This script is idempotent - safe to run multiple times."
}

main "$@"