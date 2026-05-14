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

# Clone repository on EC2 (idempotent)
clone_repository() {
    local ip="$1"
    log_step "Cloning repository on EC2 instance..."
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        # Create directories with proper permissions
        sudo mkdir -p /opt/app
        sudo mkdir -p /opt/models
        sudo chown -R ubuntu:ubuntu /opt/app
        sudo chown -R ubuntu:ubuntu /opt/models
        
        # Check if repository already exists
        if [ -d "/opt/app/music/.git" ]; then
            echo "[SKIP] Repository already cloned, updating..."
            cd /opt/app/music
            git fetch origin
            git checkout main
            git pull origin main
        else
            echo "Cloning repository..."
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

# Install system dependencies (idempotent)
install_system_dependencies() {
    local ip="$1"
    log_step "Checking system dependencies..."
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        echo "Updating system packages (if needed)..."
        sudo apt update -y 2>/dev/null || echo "[SKIP] Already up to date"
        
        # Check and install Python 3.11 (idempotent)
        if ! python3.11 --version &>/dev/null; then
            echo "Installing Python 3.11..."
            sudo apt install -y python3.11 python3.11-venv python3.11-dev
        else
            echo "[SKIP] Python 3.11 already installed: $(python3.11 --version)"
        fi
        
# Check and install Node.js 22 (latest LTS, idempotent)
        if ! node --version 2>/dev/null | grep -qE "v(2[2-9]|[3-9][0-9])"; then
            echo "Installing Node.js 22..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
            sudo apt install -y nodejs
        else
            echo "[SKIP] Node.js already installed: $(node --version)"
        fi
        
        # Check and install build tools (idempotent)
        if ! dpkg -l | grep -q "gcc"; then
            echo "Installing build tools..."
            sudo apt install -y build-essential git wget curl ffmpeg
        else
            echo "[SKIP] Build tools already installed"
        fi
        
        # Check and install nginx (idempotent)
        if ! dpkg -l | grep -q "nginx"; then
            echo "Installing nginx..."
            sudo apt install -y nginx
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
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
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
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
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
            
            # Install torch first (required for flash-attn)
            echo "Installing PyTorch..."
            pip install "torch>=2.4.0"
            
            # Install requirements (flash-attn will be installed last)
            echo "Installing other dependencies..."
            pip install -r requirements.txt || {
                echo "Some dependencies failed, trying install without flash-attn first..."
                # Install all except flash-attn, then try flash-attn separately
                grep -v "flash" requirements.txt > /tmp/requirements_no_flash.txt
                pip install -r /tmp/requirements_no_flash.txt
                echo "Installing flash-attn..."
                pip install flash-attn --no-build-isolation || {
                    echo "[WARN] flash-attn installation failed, continuing without it..."
                    echo "Flash-attention provides speed improvements but is not required for basic functionality."
                }
            }
            
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
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
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
        
        # Create .env file for production (code expects it in project root)
        if [ ! -f ".env" ]; then
            echo "Creating production .env file..."
            cat > .env << 'ENVEOF'
# ACE-Step UI Configuration (Production)

# Server
PORT=3001
NODE_ENV=production

# Database (SQLite)
DATABASE_PATH=./data/acestep.db

# ACE-Step API (local backend)
ACESTEP_API_URL=http://127.0.0.1:8001

# Storage
AUDIO_DIR=./public/audio

# Frontend
FRONTEND_URL=http://127.0.0.1:3000
VITE_API_URL=http://127.0.0.1:3001

# JWT Secret
JWT_SECRET=ace-step-ui-production-secret

# ACE-Step dtype (float32 for pre-Ampere GPUs)
ACESTEP_DTYPE=float32

# Wan2.2 Video Generation
WAN_CKPT_DIR=/opt/models/Wan2.2-T2V-A14B
WAN_GPU_DEVICE=0
ENVEOF
            echo "Created .env in project root"
        else
            echo "[SKIP] .env already exists"
        fi
        
        # Also create symlink in server/ for any tools that look there
        ln -sf ../.env server/.env 2>/dev/null || true
        
        echo "ace-step-ui setup verified"
ENDSSH
}

# Configure Nginx (idempotent)
configure_nginx() {
    local ip="$1"
    log_step "Configuring Nginx..."
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        SITES_AVAILABLE="/etc/nginx/sites-available"
        SITES_ENABLED="/etc/nginx/sites-enabled"
        SITE_CONF="$SITES_AVAILABLE/music"
        
        # Ensure directories exist
        sudo mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"
        
        # Check if nginx.conf is corrupted (contains upstream/server directives at top level)
        # This can happen if a previous script run wrote the site config to nginx.conf
        if head -n 5 /etc/nginx/nginx.conf 2>/dev/null | grep -q "^upstream\|^server"; then
            echo "WARNING: nginx.conf appears corrupted (contains upstream/server at root level)"
            echo "Restoring default nginx.conf..."
            
            # Try reinstalling nginx package to restore default config
            if sudo apt install --reinstall -o Dpkg::Options::="--force-confmiss" nginx 2>/dev/null; then
                echo "nginx.conf restored from package"
            else
                # Fallback: create a proper minimal nginx.conf
                echo "Package reinstall failed, creating default nginx.conf manually..."
                sudo tee /etc/nginx/nginx.conf > /dev/null << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
                echo "Created default nginx.conf"
            fi
            
            # Remove any corrupted backup
            sudo rm -f /etc/nginx/nginx.conf.backup
        fi
        
        # Ensure sites-enabled include exists in nginx.conf (inside http block)
        # Most Ubuntu/Debian nginx packages already have this
        # Check multiple patterns to be safe
        if ! grep -E "include.*sites-enabled|include /etc/nginx/sites-enabled" /etc/nginx/nginx.conf 2>/dev/null | grep -qv "^[[:space:]]*#"; then
            echo "Adding sites-enabled include to nginx.conf..."
            # Backup original first
            sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup 2>/dev/null || true
            
            # Use a more robust awk approach with proper newline handling
            sudo awk '{
                print
                if (/^[[:space:]]*http[[:space:]]*\{/) {
                    print "\tinclude /etc/nginx/sites-enabled/*;"
                }
            }' /etc/nginx/nginx.conf | sudo tee /etc/nginx/nginx.conf.new > /dev/null && \
            sudo mv /etc/nginx/nginx.conf.new /etc/nginx/nginx.conf
            echo "Added sites-enabled include"
        else
            echo "[SKIP] sites-enabled include already configured"
        fi
        
        # Create nginx site config
        echo "Creating nginx site config..."
        cat << 'NGINX_CONF' | sudo tee "$SITE_CONF" > /dev/null
upstream ace_step_ui {
    server 127.0.0.1:3000;
    keepalive 32;
}

upstream ace_step_backend {
    server 127.0.0.1:8001;
    keepalive 16;
}

upstream wan22_backend {
    server 127.0.0.1:8080;
    keepalive 16;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml application/xml+rss;
    
    access_log /var/log/nginx/music-access.log;
    error_log /var/log/nginx/music-error.log;
    
    location / {
        proxy_pass http://ace_step_ui;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
    
    location /api/ace-step/ {
        rewrite ^/api/ace-step/(.*) /$1 break;
        proxy_pass http://ace_step_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 300s;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 100M;
    }
    
    location /api/ace-step/ws {
        rewrite ^/api/ace-step/(.*) /$1 break;
        proxy_pass http://ace_step_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
    
    location /api/wan22/ {
        rewrite ^/api/wan22/(.*) /$1 break;
        proxy_pass http://wan22_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 7200s;
        proxy_send_timeout 7200s;
        proxy_connect_timeout 300s;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 500M;
    }
    
    location /health {
        proxy_pass http://ace_step_backend/health;
        access_log off;
    }
    
    location /api/health {
        return 200 '{"status":"healthy","service":"nginx-gateway"}';
        add_header Content-Type application/json;
        access_log off;
    }
    
    location ~ /\. {
        deny all;
    }
}
NGINX_CONF
        
        # Enable the site
        sudo ln -sf "$SITE_CONF" "$SITES_ENABLED/music"
        
        # Remove default site if exists
        sudo rm -f "$SITES_ENABLED/default"
        
        # Ensure log directory exists
        sudo mkdir -p /var/log/nginx
        
        # Test nginx config
        if sudo nginx -t; then
            echo "Nginx configuration is valid"
        else
            echo "ERROR: Nginx configuration is invalid"
            # Restore backup if available
            if [ -f /etc/nginx/nginx.conf.backup ]; then
                echo "Restoring nginx.conf from backup..."
                sudo cp /etc/nginx/nginx.conf.backup /etc/nginx/nginx.conf
            fi
            echo "=== nginx.conf contents ==="
            cat /etc/nginx/nginx.conf
            echo "=== site config contents ==="
            cat "$SITE_CONF"
            exit 1
        fi
        
        echo "Nginx configured"
ENDSSH
}

# Copy systemd service files (idempotent)
copy_systemd_services() {
    local ip="$1"
    log_step "Copying systemd service files..."
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        SERVICES_DIR="/opt/app/music/infra/configs/systemd"
        SYSTEM_DIR="/etc/systemd/system"
        
        # Create directories
        sudo mkdir -p "$SERVICES_DIR"
        mkdir -p /opt/app/music/ACE-Step-1.5
        mkdir -p /opt/app/music/Wan2.2
        mkdir -p /opt/app/music/ace-step-ui/server
        sudo mkdir -p /opt/logs
        
        # Create ace-step-1.5.service if not exists
        if [ ! -f "$SERVICES_DIR/ace-step-1.5.service" ]; then
            echo "Creating ace-step-1.5.service..."
            cat << 'SERVICE_CONF' | sudo tee "$SERVICES_DIR/ace-step-1.5.service" > /dev/null
[Unit]
Description=ACE-Step 1.5 Music Generation API Server
Documentation=https://github.com/sinke237/music
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/app/music/ACE-Step-1.5

Environment="CUDA_VISIBLE_DEVICES=0"
Environment="ACESTEP_INIT_LLM=auto"
Environment="ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-1.7B"
Environment="ACESTEP_CONFIG_PATH=acestep-v15-turbo"
Environment="ACESTEP_DOWNLOAD_SOURCE=auto"
Environment="ACESTEP_OFFLOAD_TO_CPU=true"
Environment="ACESTEP_OFFLOAD_DIT_TO_CPU=true"
Environment="ACESTEP_CHECKPOINTS_DIR=/opt/models/acestep"
Environment="PORT=8001"
Environment="SERVER_NAME=127.0.0.1"
Environment="HOST=127.0.0.1"

ExecStartPre=/bin/bash -c 'source /home/ubuntu/.bashrc && export PATH="$HOME/.local/bin:$PATH"'
ExecStart=/home/ubuntu/.local/bin/uv run acestep-api --host 127.0.0.1 --port 8001 --enable-api --backend pt --server-name 127.0.0.1

Restart=on-failure
RestartSec=30
TimeoutStartSec=600
TimeoutStopSec=120

StandardOutput=append:/opt/logs/ace-step-1.5.log
StandardError=append:/opt/logs/ace-step-1.5-error.log

MemoryHigh=60G
MemoryMax=64G
CPUWeight=80
IOWeight=80
Nice=0

[Install]
WantedBy=multi-user.target
SERVICE_CONF
        else
            echo "[SKIP] ace-step-1.5.service already exists"
        fi
        
        # Create wan22.service if not exists
        if [ ! -f "$SERVICES_DIR/wan22.service" ]; then
            echo "Creating wan22.service..."
            cat << 'SERVICE_CONF' | sudo tee "$SERVICES_DIR/wan22.service" > /dev/null
[Unit]
Description=Wan2.2 Video Generation API Server
Documentation=https://github.com/sinke237/music
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/app/music/Wan2.2

Environment="CUDA_VISIBLE_DEVICES=0"
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONDONTWRITEBYTECODE=1"

ExecStart=/opt/app/music/Wan2.2/.venv/bin/python generate.py --task ti2v-5B --size 1280x704 --ckpt_dir /opt/models/Wan2.2-TI2V-5B --offload_model True --convert_model_dtype --t5_cpu --port 8080

Restart=on-failure
RestartSec=30
TimeoutStartSec=1200
TimeoutStopSec=300

StandardOutput=append:/opt/logs/wan22.log
StandardError=append:/opt/logs/wan22-error.log

MemoryHigh=20G
MemoryMax=24G
CPUWeight=90
IOWeight=90
Nice=-5

[Install]
WantedBy=multi-user.target
SERVICE_CONF
        else
            echo "[SKIP] wan22.service already exists"
        fi
        
        # Create ace-step-ui.service if not exists
        if [ ! -f "$SERVICES_DIR/ace-step-ui.service" ]; then
            echo "Creating ace-step-ui.service..."
            cat << 'SERVICE_CONF' | sudo tee "$SERVICES_DIR/ace-step-ui.service" > /dev/null
[Unit]
Description=ACE-Step UI Frontend Server
Documentation=https://github.com/sinke237/music
After=network.target network-online.target ace-step-1.5.service
Wants=network-online.target
Requires=ace-step-1.5.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/app/music/ace-step-ui
Environment="NODE_ENV=production"
Environment="PORT=3000"
Environment="ACESTEP_API_URL=http://127.0.0.1:8001"
Environment="WAN22_API_URL=http://127.0.0.1:8080"

ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/npm start

Restart=on-failure
RestartSec=15
TimeoutStartSec=120
TimeoutStopSec=30

StandardOutput=append:/opt/logs/ace-step-ui.log
StandardError=append:/opt/logs/ace-step-ui-error.log

MemoryHigh=8G
MemoryMax=10G
CPUWeight=50
IOWeight=50
Nice=5

[Install]
WantedBy=multi-user.target
SERVICE_CONF
        else
            echo "[SKIP] ace-step-ui.service already exists"
        fi
        
        # Create nginx.service if not exists
        if [ ! -f "$SERVICES_DIR/nginx.service" ]; then
            echo "Creating nginx.service..."
            cat << 'SERVICE_CONF' | sudo tee "$SERVICES_DIR/nginx.service" > /dev/null
[Unit]
Description=Nginx HTTP Server (API Gateway)
Documentation=https://nginx.org/en/docs/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE_CONF
        else
            echo "[SKIP] nginx.service already exists"
        fi
        
        # Install services to systemd
        NEED_RELOAD=0
        
        for service in ace-step-1.5.service wan22.service ace-step-ui.service nginx.service; do
            if [ ! -f "$SYSTEM_DIR/$service" ] || ! cmp -s "$SERVICES_DIR/$service" "$SYSTEM_DIR/$service"; then
                echo "Installing $service..."
                sudo cp "$SERVICES_DIR/$service" "$SYSTEM_DIR/$service"
                NEED_RELOAD=1
            else
                echo "[SKIP] $service already up to date"
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
    
    ssh -i "$KEY_PATH" ubuntu@"$ip" << 'ENDSSH'
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
    
    # Step 1: Clone repository (idempotent)
    clone_repository "$EC2_IP"
    
    # Step 2: Install system dependencies (idempotent)
    install_system_dependencies "$EC2_IP"
    
    # Step 3: Setup ACE-Step-1.5 (idempotent)
    setup_ace_step "$EC2_IP"
    
    # Step 4: Setup Wan2.2 (idempotent)
    setup_wan22 "$EC2_IP"
    
    # Step 5: Setup ace-step-ui (idempotent)
    setup_ace_step_ui "$EC2_IP"
    
    # Step 6: Configure Nginx (idempotent)
    configure_nginx "$EC2_IP"
    
    # Step 7: Copy systemd service files (idempotent)
    copy_systemd_services "$EC2_IP"
    
    # Step 8: Start all services (idempotent)
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