/**
 * GPU Service Manager - On-demand GPU service management
 * 
 * Manages ACE-Step and Wan2.2 GPU services:
 * - Starts services on-demand when generation is requested
 * - Ensures mutual exclusion (only one GPU service at a time)
 * - Auto-stops after idle timeout
 */

import { spawn, exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

// Configuration
const GPU_ON_DEMAND = process.env.GPU_ON_DEMAND === 'true';
const GPU_ON_DEMAND_SCRIPT = process.env.GPU_ON_DEMAND_SCRIPT || '/opt/scripts/gpu-on-demand.sh';
const GPU_IDLE_TIMEOUT = parseInt(process.env.GPU_IDLE_TIMEOUT || '300', 10); // 5 minutes default

// Service names
const ACE_STEP_SERVICE = 'ace-step-1.5';
const WAN22_SERVICE = 'wan22';

// State tracking
let currentService: 'ace-step' | 'wan22' | null = null;
let idleTimer: NodeJS.Timeout | null = null;
let serviceStartTime: number = 0;

interface ServiceStatus {
  aceStep: boolean;
  wan22: boolean;
}

/**
 * Execute a shell command
 */
async function runCommand(cmd: string): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout: 30000 }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`Command failed: ${cmd}\n${stderr || error.message}`));
      } else {
        resolve({ stdout, stderr });
      }
    });
  });
}

/**
 * Check if a systemd service is running
 */
async function isServiceRunning(service: string): Promise<boolean> {
  try {
    await runCommand(`systemctl is-active --quiet ${service}`);
    return true;
  } catch {
    return false;
  }
}

/**
 * Get current service status
 */
export async function getServiceStatus(): Promise<ServiceStatus> {
  const [aceStep, wan22] = await Promise.all([
    isServiceRunning(ACE_STEP_SERVICE),
    isServiceRunning(WAN22_SERVICE),
  ]);
  return { aceStep, wan22 };
}

/**
 * Stop idle timer
 */
function stopIdleTimer(): void {
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
}

/**
 * Start idle timer to auto-stop service after timeout
 */
function startIdleTimer(): void {
  stopIdleTimer();
  
  if (GPU_IDLE_TIMEOUT > 0) {
    idleTimer = setTimeout(async () => {
      console.log(`[GPU-Manager] Idle timeout (${GPU_IDLE_TIMEOUT}s) reached, stopping GPU service...`);
      await stopCurrentService();
    }, GPU_IDLE_TIMEOUT * 1000);
  }
}

/**
 * Stop the current GPU service
 */
export async function stopCurrentService(): Promise<void> {
  if (!currentService) {
    return;
  }
  
  const service = currentService === 'ace-step' ? ACE_STEP_SERVICE : WAN22_SERVICE;
  console.log(`[GPU-Manager] Stopping ${service}...`);
  
  try {
    await runCommand(`sudo systemctl stop ${service}`);
    currentService = null;
    serviceStartTime = 0;
    console.log(`[GPU-Manager] ${service} stopped`);
  } catch (error) {
    console.error(`[GPU-Manager] Failed to stop ${service}:`, error);
  }
}

/**
 * Ensure ACE-Step is running (start if not)
 * Returns true if service was started, false if already running
 */
export async function ensureAceStepRunning(): Promise<boolean> {
  const status = await getServiceStatus();
  
  // If Wan2.2 is running, stop it first (mutual exclusion)
  if (status.wan22) {
    console.log('[GPU-Manager] Wan2.2 is running, stopping it (mutual exclusion)...');
    await runCommand(`sudo systemctl stop ${WAN22_SERVICE}`);
    // Wait for GPU to be freed
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
  
  // If ACE-Step is already running, reset idle timer
  if (status.aceStep) {
    console.log('[GPU-Manager] ACE-Step already running, resetting idle timer');
    currentService = 'ace-step';
    startIdleTimer();
    return false;
  }
  
  // Start ACE-Step
  console.log('[GPU-Manager] Starting ACE-Step...');
  
  if (GPU_ON_DEMAND && process.platform === 'linux') {
    // Use on-demand script if available
    try {
      await runCommand(`${GPU_ON_DEMAND_SCRIPT} start-ace-step`);
    } catch (error) {
      console.warn('[GPU-Manager] On-demand script failed, using systemctl:', error);
      await runCommand(`sudo systemctl start ${ACE_STEP_SERVICE}`);
    }
  } else {
    await runCommand(`sudo systemctl start ${ACE_STEP_SERVICE}`);
  }
  
  // Wait for service to be ready
  let retries = 30;
  while (retries > 0) {
    try {
      const response = await fetch('http://localhost:8001/health');
      if (response.ok) {
        const data = await response.json();
        console.log(`[GPU-Manager] ACE-Step ready:`, data);
        currentService = 'ace-step';
        serviceStartTime = Date.now();
        startIdleTimer();
        return true;
      }
    } catch {
      // Service not ready yet
    }
    
    retries--;
    await new Promise(resolve => setTimeout(resolve, 2000));
  }
  
  throw new Error('ACE-Step failed to start within timeout');
}

/**
 * Ensure Wan2.2 is running (start if not)
 * Returns true if service was started, false if already running
 */
export async function ensureWan22Running(): Promise<boolean> {
  const status = await getServiceStatus();
  
  // If ACE-Step is running, stop it first (mutual exclusion)
  if (status.aceStep) {
    console.log('[GPU-Manager] ACE-Step is running, stopping it (mutual exclusion)...');
    await runCommand(`sudo systemctl stop ${ACE_STEP_SERVICE}`);
    // Wait for GPU to be freed
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
  
  // If Wan2.2 is already running, reset idle timer
  if (status.wan22) {
    console.log('[GPU-Manager] Wan2.2 already running, resetting idle timer');
    currentService = 'wan22';
    startIdleTimer();
    return false;
  }
  
  // Start Wan2.2
  console.log('[GPU-Manager] Starting Wan2.2...');
  
  if (GPU_ON_DEMAND && process.platform === 'linux') {
    try {
      await runCommand(`${GPU_ON_DEMAND_SCRIPT} start-wan22`);
    } catch (error) {
      console.warn('[GPU-Manager] On-demand script failed, using systemctl:', error);
      await runCommand(`sudo systemctl start ${WAN22_SERVICE}`);
    }
  } else {
    await runCommand(`sudo systemctl start ${WAN22_SERVICE}`);
  }
  
  // Wait for service to be ready
  let retries = 60;
  while (retries > 0) {
    try {
      const response = await fetch('http://localhost:8080/health');
      if (response.ok) {
        console.log('[GPU-Manager] Wan2.2 ready');
        currentService = 'wan22';
        serviceStartTime = Date.now();
        startIdleTimer();
        return true;
      }
    } catch {
      // Service not ready yet
    }
    
    retries--;
    await new Promise(resolve => setTimeout(resolve, 2000));
  }
  
  throw new Error('Wan2.2 failed to start within timeout');
}

/**
 * Reset idle timer (call this when there's activity)
 */
export function resetIdleTimer(): void {
  startIdleTimer();
}

/**
 * Get current service info
 */
export function getCurrentService(): { service: 'ace-step' | 'wan22' | null; uptime: number } {
  return {
    service: currentService,
    uptime: currentService ? (Date.now() - serviceStartTime) / 1000 : 0,
  };
}