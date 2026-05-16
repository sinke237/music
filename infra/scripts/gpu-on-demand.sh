#!/bin/bash
# =============================================================================
# On-Demand Service Starter
# Called by ace-step-ui backend to start/stop GPU services as needed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/gpu-services.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Start ACE-Step and stop Wan2.2 if running
start_ace_step() {
    log "[GPU-MANAGER] Starting ACE-Step (stopping Wan2.2 if running)..."
    
    # Stop Wan2.2 if running (systemd Conflicts will handle this but be explicit)
    if systemctl is-active --quiet wan22 2>/dev/null; then
        log "[GPU-MANAGER] Stopping Wan2.2..."
        sudo systemctl stop wan22 || true
        # Wait for GPU to be freed
        sleep 10
    fi
    
    # Start ACE-Step
    if ! systemctl is-active --quiet ace-step-1.5 2>/dev/null; then
        log "[GPU-MANAGER] Starting ACE-Step..."
        sudo systemctl start ace-step-1.5
        
        # Wait for service to be ready
        local timeout=60
        local start_time=$(date +%s)
        while ! curl -s http://localhost:8001/health > /dev/null 2>&1; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            if [ "$elapsed" -ge "$timeout" ]; then
                log "[GPU-MANAGER] ERROR: ACE-Step failed to start within ${timeout}s"
                return 1
            fi
            sleep 2
        done
        log "[GPU-MANAGER] ACE-Step is ready"
    else
        log "[GPU-MANAGER] ACE-Step already running"
    fi
    
    return 0
}

# Start Wan2.2 and stop ACE-Step if running
start_wan22() {
    log "[GPU-MANAGER] Starting Wan2.2 (stopping ACE-Step if running)..."
    
    # Stop ACE-Step if running
    if systemctl is-active --quiet ace-step-1.5 2>/dev/null; then
        log "[GPU-MANAGER] Stopping ACE-Step..."
        sudo systemctl stop ace-step-1.5 || true
        # Wait for GPU to be freed
        sleep 10
    fi
    
    # Start Wan2.2
    if ! systemctl is-active --quiet wan22 2>/dev/null; then
        log "[GPU-MANAGER] Starting Wan2.2..."
        sudo systemctl start wan22
        
        # Wait for service to be ready
        local timeout=120
        local start_time=$(date +%s)
        while ! curl -s http://localhost:8080/health > /dev/null 2>&1; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            if [ "$elapsed" -ge "$timeout" ]; then
                log "[GPU-MANAGER] ERROR: Wan2.2 failed to start within ${timeout}s"
                return 1
            fi
            sleep 2
        done
        log "[GPU-MANAGER] Wan2.2 is ready"
    else
        log "[GPU-MANAGER] Wan2.2 already running"
    fi
    
    return 0
}

# Stop service after generation to free GPU
stop_service() {
    local service="$1"
    
    case "$service" in
        ace-step|ace-step-1.5)
            log "[GPU-MANAGER] Stopping ACE-Step to free GPU..."
            sudo systemctl stop ace-step-1.5 || true
            ;;
        wan22|wan2.2)
            log "[GPU-MANAGER] Stopping Wan2.2 to free GPU..."
            sudo systemctl stop wan22 || true
            ;;
    esac
    
    # Allow GPU memory to be freed
    sleep 5
    log "[GPU-MANAGER] GPU freed"
}

# Check if service is running
is_running() {
    local service="$1"
    case "$service" in
        ace-step|ace-step-1.5)
            systemctl is-active --quiet ace-step-1.5 2>/dev/null
            ;;
        wan22|wan2.2)
            systemctl is-active --quiet wan22 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Get GPU status
gpu_status() {
    echo "=== GPU Status ==="
    nvidia-smi --query-gpu=memory.used,memory.free --format=csv
    echo ""
    echo "=== Services ==="
    echo "ACE-Step: $(systemctl is-active ace-step-1.5 2>/dev/null || echo 'stopped')"
    echo "Wan2.2: $(systemctl is-active wan22 2>/dev/null || echo 'stopped')"
}

# Main
case "${1:-help}" in
    start-ace-step)
        start_ace_step
        ;;
    start-wan22)
        start_wan22
        ;;
    stop-ace-step)
        stop_service "ace-step"
        ;;
    stop-wan22)
        stop_service "wan22"
        ;;
    status)
        gpu_status
        ;;
    is-running)
        is_running "${2:-ace-step}"
        ;;
    *)
        echo "Usage: $0 {start-ace-step|start-wan22|stop-ace-step|stop-wan22|status}"
        echo ""
        echo "On-Demand GPU Service Manager"
        echo "  start-ace-step  - Start ACE-Step (stops Wan2.2 if running)"
        echo "  start-wan22     - Start Wan2.2 (stops ACE-Step if running)"
        echo "  stop-ace-step   - Stop ACE-Step to free GPU"
        echo "  stop-wan22      - Stop Wan2.2 to free GPU"
        echo "  status          - Show GPU and service status"
        exit 1
        ;;
esac