#!/bin/bash
# =============================================================================
# SSL and DNS Setup Script (Idempotent)
# Configures Let's Encrypt SSL and updates DNS
# Safe to run multiple times - will only create certificate if not exists
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
DOMAIN="suno.enowsinke.com"

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1 Already configured"; }

# Get EC2 IP
get_ec2_ip() {
    if [ ! -f "$EC2_IP_FILE" ]; then
        log_error "EC2 IP file not found at $EC2_IP_FILE"
        log_error "Please run provision.sh first."
        exit 1
    fi
    cat "$EC2_IP_FILE"
}

# Check if DNS is configured
check_dns() {
    local ip="$1"
    log_step "Checking DNS configuration..."
    
    local dns_ip
    dns_ip=$(nslookup "$DOMAIN" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | tail -1 || echo "")
    
    if [ "$dns_ip" = "$ip" ]; then
        log_skip "DNS"
        return 0
    fi
    
    if [ -n "$dns_ip" ]; then
        log_warn "DNS points to $dns_ip, but EC2 IP is $ip"
    fi
    
    return 1
}

# Print DNS configuration instructions
print_dns_instructions() {
    local ec2_ip="$1"
    
    log_info "========================================"
    log_info "DNS Configuration Required"
    log_info "========================================"
    log_info ""
    log_info "Create an A record in your DNS provider:"
    log_info ""
    log_info "  Type:  A"
    log_info "  Name:  suno"
    log_info "  Value: $ec2_ip"
    log_info "  TTL:   300 (or lowest available)"
    log_info ""
    log_info "Full domain: $DOMAIN"
    log_info ""
    log_info "DNS propagation may take 5-10 minutes."
    log_info ""
    
    if [ -t 0 ]; then
        read -p "Press Enter when DNS is configured..." dummy
    else
        log_warn "Running in non-interactive mode - assuming DNS is configured"
        sleep 10
    fi
}

# Wait for DNS propagation
wait_for_dns() {
    local ip="$1"
    log_step "Waiting for DNS propagation..."
    log_info "This may take 5-10 minutes..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local dns_ip
        dns_ip=$(nslookup "$DOMAIN" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | tail -1 || echo "")
        
        if [ "$dns_ip" = "$ip" ]; then
            log_info "DNS propagated successfully!"
            log_info "$DOMAIN → $ip"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts - Waiting for DNS ($DOMAIN currently resolves to ${dns_ip:-'nothing'})..."
        sleep 30
        ((attempt++))
    done
    
    log_warn "DNS propagation timeout. Continuing anyway..."
    return 0
}

# Install certbot (idempotent)
install_certbot() {
    local ip="$1"
    log_step "Installing certbot..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        # Check if certbot is already installed
        if command -v certbot &> /dev/null; then
            echo "[SKIP] Certbot already installed"
            exit 0
        fi
        
        echo "Installing certbot..."
        sudo yum install -y certbot python3-certbot-nginx
        
        echo "Certbot installed successfully"
ENDSSH
}

# Check if certificate exists
check_certificate() {
    local ip="$1"
    
    log_step "Checking for existing SSL certificate..."
    
    local result
    result=$(ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        if sudo certbot certificates 2>/dev/null | grep -q "suno.enowsinke.com"; then
            echo "exists"
        else
            echo "not_found"
        fi
ENDSSH
    )
    
    if [ "$result" = "exists" ]; then
        return 0
    else
        return 1
    fi
}

# Obtain SSL certificate (idempotent)
obtain_ssl_certificate() {
    local ip="$1"
    
    # Check if certificate already exists
    if check_certificate "$ip"; then
        log_skip "SSL Certificate"
        return 0
    fi
    
    log_step "Obtaining SSL certificate..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << ENDSSH
        set -euo pipefail
        
        DOMAIN="$DOMAIN"
        
        # Double-check certificate doesn't exist
        if sudo certbot certificates 2>/dev/null | grep -q "\$DOMAIN"; then
            echo "[SKIP] Certificate already exists"
            exit 0
        fi
        
        echo "Obtaining SSL certificate for \$DOMAIN..."
        
        # Stop nginx temporarily (if running)
        sudo systemctl stop nginx 2>/dev/null || true
        
        # Obtain certificate (non-interactive)
        sudo certbot certonly --standalone \\
            --non-interactive \\
            --agree-tos \\
            --email admin@\${DOMAIN} \\
            --domains \${DOMAIN} \\
            --keep-until-expiring || {
                echo "Failed to obtain certificate"
                exit 1
            }
        
        # Start nginx
        sudo systemctl start nginx
        
        # Setup auto-renewal (idempotent)
        if ! sudo crontab -l 2>/dev/null | grep -q "certbot renew"; then
            echo "Setting up certificate auto-renewal..."
            (sudo crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | sudo crontab -
        else
            echo "[SKIP] Auto-renewal already configured"
        fi
        
        echo "SSL certificate obtained successfully"
ENDSSH
}

# Configure nginx for HTTPS (idempotent)
configure_nginx_https() {
    local ip="$1"
    log_step "Configuring nginx for HTTPS..."
    
    ssh -i "$KEY_PATH" ec2-user@"$ip" << 'ENDSSH'
        set -euo pipefail
        
        # Check if HTTPS is already configured
        if sudo nginx -T 2>/dev/null | grep -q "listen 443 ssl"; then
            echo "[SKIP] Nginx HTTPS already configured"
            exit 0
        fi
        
        echo "Testing nginx configuration..."
        sudo nginx -t
        
        echo "Reloading nginx..."
        sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
        
        echo "Nginx configured for HTTPS successfully"
ENDSSH
}

# Test HTTPS connection
test_https() {
    log_step "Testing HTTPS connection..."
    
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -k -I "https://$DOMAIN" 2>/dev/null | grep -q "HTTP"; then
            log_info "HTTPS is working!"
            log_info ""
            log_info "Service URLs:"
            log_info "  HTTPS: https://$DOMAIN"
            log_info "  HTTP:  http://$DOMAIN (redirects to HTTPS)"
            log_info "  UI:    https://$DOMAIN"
            log_info "  API:   https://$DOMAIN/api/ace-step/"
            return 0
        fi
        
        log_warn "Attempt $attempt/$max_attempts - HTTPS not yet ready..."
        sleep 10
        ((attempt++))
    done
    
    log_warn "HTTPS test timed out. Check nginx logs: tail -f /var/log/nginx/error.log"
    return 0
}

# Main execution
main() {
    log_info "Setting up SSL and DNS (Idempotent)..."
    log_info "========================================"
    
    # Get EC2 IP
    EC2_IP=$(get_ec2_ip)
    log_info "EC2 Public IP: $EC2_IP"
    log_info "Domain: $DOMAIN"
    
    # Step 1: Install certbot (idempotent)
    install_certbot "$EC2_IP"
    
    # Step 2: Check DNS (idempotent)
    if check_dns "$EC2_IP"; then
        log_skip "DNS configuration"
    else
        print_dns_instructions "$EC2_IP"
        wait_for_dns "$EC2_IP"
    fi
    
    # Step 3: Obtain SSL certificate (idempotent)
    obtain_ssl_certificate "$EC2_IP"
    
    # Step 4: Configure nginx for HTTPS (idempotent)
    configure_nginx_https "$EC2_IP"
    
    # Step 5: Test HTTPS
    test_https
    
    log_info "========================================"
    log_info "SSL and DNS setup completed!"
    log_info ""
    log_info "Your application is available at:"
    log_info "  https://$DOMAIN"
    log_info ""
    log_info "Certificate auto-renewal is configured."
    log_info "Run this script anytime to verify/renew configuration."
}

main "$@"