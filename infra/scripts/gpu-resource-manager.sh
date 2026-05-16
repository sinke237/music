#!/bin/bash
# =============================================================================
# GPU Resource Manager
# Ensures ACE-Step-1.5 and Wan2.2 don't run simultaneously
# Provides on-demand GPU allocation with automatic offloading
# =============================================================================

set -euo pipefail

LOCK_DIR="/var/run/gpu-manager"
ACE_STEP_LOCK="$LOCK_DIR/ace-step.lock"
WAN22_LOCK="$LOCK_DIR/wan22.lock"
GPU_LOCK="$LOCK_DIR/gpu.lock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[GPU-Manager]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[GPU-Manager]${NC} $1"; }
log_error() { echo -e "${RED}[GPU-Manager]${NC} $1"; }

# Ensure lock directory exists
ensure_lock_dir() {
    sudo mkdir -p "$LOCK_DIR"
    sudo chmod 777 "$LOCK_DIR"
}

# Acquire GPU lock for a service
# Usage: acquire_gpu <service_name> <timeout_seconds>
acquire_gpu() {
    local service="$1"
    local timeout="${2:-300}"
    
    ensure_lock_dir
    
    local service_lock="$LOCK_DIR/${service}.lock"
    
    # Check if other service is running
    local other_service=""
    if [ "$service" = "ace-step" ]; then
        other_service="wan22"
    else
        other_service="ace-step"
    fi
    
    local other_lock="$LOCK_DIR/${other_service}.lock"
    
    # Wait for GPU lock with timeout
    local start_time=$(date +%s)
    while true; do
        # Try to acquire GPU lock
        if (set -C; echo $$ > "$GPU_LOCK") 2>/dev/null; then
            # Got GPU lock, now check/create service lock
            echo "$service" > "$service_lock"
            log_info "GPU acquired by $service (PID: $$)"
            return 0
        fi
        
        # Check timeout
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "Timeout waiting for GPU lock"
            return 1
        fi
        
        # Check who has the lock
        if [ -f "$GPU_LOCK" ]; then
            local lock_holder=$(cat "$GPU_LOCK" 2>/dev/null || echo "unknown")
            log_warn "Waiting for GPU lock (held by PID $lock_holder, ${elapsed}s/${timeout}s)"
        fi
        
        sleep 2
    done
}

# Release GPU lock
# Usage: release_gpu <service_name>
release_gpu() {
    local service="$1"
    local service_lock="$LOCK_DIR/${service}.lock"
    
    # Only release if we own it
    if [ -f "$service_lock" ]; then
        local lock_owner=$(cat "$service_lock" 2>/dev/null || echo "")
        if [ "$lock_owner" = "$service" ]; then
            rm -f "$service_lock"
            rm -f "$GPU_LOCK"
            log_info "GPU released by $service"
        fi
    fi
}

# Check GPU status
gpu_status() {
    ensure_lock_dir
    
    echo "=== GPU Resource Status ==="
    echo ""
    
    # Check locks
    if [ -f "$GPU_LOCK" ]; then
        echo "GPU Lock: HELD by $(cat "$GPU_LOCK" 2>/dev/null || echo 'unknown')"
    else
        echo "GPU Lock: FREE"
    fi
    
    echo ""
    echo "Service Locks:"
    for svc in ace-step wan22; do
        local lock="$LOCK_DIR/${svc}.lock"
        if [ -f "$lock" ]; then
            echo "  - $svc: LOCKED"
        else
            echo "  - $svc: free"
        fi
    done
    
    echo ""
    echo "GPU Memory:"
    nvidia-smi --query-gpu=memory.used,memory.free,memory.total --format=csv,noheader 2>/dev/null || echo "  (nvidia-smi not available)"
    
    echo ""
    echo "Running Services:"
    systemctl is-active ace-step-1.5 2>/dev/null && echo "  - ace-step-1.5: RUNNING" || echo "  - ace-step-1.5: STOPPED"
    systemctl is-active wan22 2>/dev/null && echo "  - wan22: RUNNING" || echo "  - wan22: STOPPED"
}

# Stop other service and wait for GPU release
# Usage: stop_for_gpu <my_service> <timeout_seconds>
stop_for_gpu() {
    local my_service="$1"
    local timeout="${2:-120}"
    
    local other_service=""
    local other_systemd=""
    
    if [ "$my_service" = "ace-step" ]; then
        other_service="wan22"
        other_systemd="wan22"
    else
        other_service="ace-step"
        other_systemd="ace-step-1.5"
    fi
    
    # Check if other service is running
    if systemctl is-active --quiet "$other_systemd" 2>/dev/null; then
        log_warn "$other_service is running, stopping it..."
        sudo systemctl stop "$other_systemd"
        
        # Wait for GPU to be freed
        local start_time=$(date +%s)
        while systemctl is-active --quiet "$other_systemd" 2>/dev/null; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            if [ "$elapsed" -ge "$timeout" ]; then
                log_error "Timeout waiting for $other_service to stop"
                return 1
            fi
            log_info "Waiting for $other_service to stop (${elapsed}s/${timeout}s)"
            sleep 2
        done
        
        # Additional wait for GPU memory to be freed
        log_info "Waiting for GPU memory to be released..."
        sleep 10
    fi
    
    return 0
}

# Start service with GPU allocation
# Usage: start_service <service_name> <timeout_seconds>
start_service() {
    local my_service="$1"
    local timeout="${2:-300}"
    
    local my_systemd=""
    if [ "$my_service" = "ace-step" ]; then
        my_systemd="ace-step-1.5"
    else
        my_systemd="wan22"
    fi
    
    # Stop competing service
    stop_for_gpu "$my_service" "$timeout"
    
    # Start the service
    log_info "Starting $my_systemd..."
    sudo systemctl start "$my_systemd"
    
    # Wait for service to be ready
    local start_time=$(date +%s)
    while ! systemctl is-active --quiet "$my_systemd" 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "Timeout waiting for $my_service to start"
            return 1
        fi
        sleep 2
    done
    
    log_info "$my_service started successfully"
    return 0
}

# Webhook endpoint for on-demand generation
# This can be called by the API to ensure GPU availability
ensure_gpu_for() {
    local service="$1"
    local timeout="${2:-300}"
    
    case "$service" in
        ace-step|ace-step-1.5)
            start_service "ace-step" "$timeout"
            ;;
        wan22|wan2.2)
            start_service "wan22" "$timeout"
            ;;
        *)
            log_error "Unknown service: $service"
            return 1
            ;;
    esac
}

# Release GPU after generation
# Usage: release_gpu_after <service_name>
release_gpu_after() {
    local service="$1"
    local systemd_service=""
    
    if [ "$service" = "ace-step" ]; then
        systemd_service="ace-step-1.5"
    else
        systemd_service="wan22"
    fi
    
    # Stop the service to release GPU
    log_info "Stopping $systemd_service to release GPU..."
    sudo systemctl stop "$systemd_service"
    
    # Wait for GPU memory to be freed
    sleep 5
    
    release_gpu "$service"
}

# Main command handler
case "${1:-}" in
    acquire)
        acquire_gpu "${2:-ace-step}" "${3:-300}"
        ;;
    release)
        release_gpu "${2:-ace-step}"
        ;;
    status)
        gpu_status
        ;;
    stop-for)
        stop_for_gpu "${2:-ace-step}" "${3:-120}"
        ;;
    start)
        start_service "${2:-ace-step}" "${3:-300}"
        ;;
    ensure)
        ensure_gpu_for "${2:-ace-step}" "${3:-300}"
        ;;
    release-after)
        release_gpu_after "${2:-ace-step}"
        ;;
    *)
        echo "GPU Resource Manager"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  status                    Show GPU and service status"
        echo "  acquire <service> [timeout]    Acquire GPU lock"
        echo "  release <service>              Release GPU lock"
        echo "  start <service> [timeout]      Start service (stop other if running)"
        echo "  ensure <service> [timeout]     Ensure service is running (stop other)"
        echo "  release-after <service>        Stop service and release GPU"
        echo ""
        echo "Services: ace-step, wan22"
        echo ""
        echo "Examples:"
        echo "  $0 status"
        echo "  $0 start ace-step"
        echo "  $0 ensure wan22"
        echo "  $0 release-after ace-step"
        ;;
esac