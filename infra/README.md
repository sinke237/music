# Music Generation Infrastructure

Production-ready AWS infrastructure for deploying AI music and video generation services.

## Overview

This infrastructure deploys services on a single EC2 GPU instance with on-demand GPU resource management:

| Service | Type | Port | GPU Usage |
|---------|------|------|-----------|
| nginx | API Gateway | 80 | N/A (always running) |
| ace-step-ui | Frontend + API | 3000/3001 | N/A (always running) |
| ace-step-1.5 | Music Generation | 8001 | ~7GB (on-demand) |
| wan2.2 | Video Generation | 8080 | ~15-18GB (on-demand) |

## Instance Configuration

### GPU Instance

- **GPU**: 1 x NVIDIA A10G (22GB VRAM)
- **Models**: g5.4xlarge, g6.4xlarge, or similar
- **vCPUs**: 16
- **Memory**: 64GB
- **Disk**: 200GB+ (models require ~160GB)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        EC2 Instance                                  │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Always Running                             │   │
│  │  ┌─────────────┐    ┌──────────────────────────────────────┐ │   │
│  │  │   Nginx     │    │           ace-step-ui                │ │   │
│  │  │   (80)      │    │  Frontend (3000) + Backend API (3001)│ │   │
│  │  │   Gateway   │    │  Spotify-like web interface          │ │   │
│  │  └──────┬──────┘    └──────────────────────────────────────┘ │   │
│  └─────────┼─────────────────────────────────────────────────────┘   │
│            │                                                         │
│            │ /api/ace-step/*                 /api/wan22/*           │
│            │                                 │                       │
│            ▼                                 ▼                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │               On-Demand GPU Services                          │   │
│  │                (Mutual Exclusion)                             │   │
│  │                                                               │   │
│  │  ┌─────────────────┐        ┌─────────────────┐              │   │
│  │  │   ace-step-1.5  │◄──────►│     wan2.2     │              │   │
│  │  │   Port: 8001    │ never  │   Port: 8080   │              │   │
│  │  │   GPU: ~7GB     │  run   │   GPU: ~15-18GB│              │   │
│  │  │   simultaneously│        │                 │              │   │
│  │  └─────────────────┘        └─────────────────┘              │   │
│  │                                                               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │               GPU Resource Manager                            │   │
│  │  /opt/scripts/gpu-on-demand.sh                               │   │
│  │  - Starts GPU services on-demand                              │   │
│  │  - Ensures mutual exclusion (only one at a time)              │   │
│  │  - Offloads to CPU when idle                                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## GPU Resource Management

### On-Demand Service Architecture

GPU services (ACE-Step, Wan2.2) are **not started by default**. They are started on-demand when needed:

```bash
# Start ACE-Step (stops Wan2.2 if running)
/opt/scripts/gpu-on-demand.sh start-ace-step

# Start Wan2.2 (stops ACE-Step if running)
/opt/scripts/gpu-on-demand.sh start-wan22

# Stop services to free GPU memory
/opt/scripts/gpu-on-demand.sh stop-ace-step
/opt/scripts/gpu-on-demand.sh stop-wan22

# Check status
/opt/scripts/gpu-on-demand.sh status
```

### Mutual Exclusion

Systemd `Conflicts=` directive ensures ACE-Step and Wan2.2 never run simultaneously:

```ini
# ace-step-1.5.service
Conflicts=wan22.service

# wan22.service
Conflicts=ace-step-1.5.service
```

### GPU Memory Allocation

| Service | Model | VRAM | Configuration |
|---------|-------|------|---------------|
| ACE-Step 1.5 | acestep-v15-turbo + 1.7B LLM | ~7GB | CPU offload enabled |
| Wan2.2 | Wan2.2-T2V-A14B | ~15-18GB | Model offload enabled |

**Total GPU**: 22GB VRAM (A10G)

### Models Used

**ACE-Step 1.5**:
- Main model: `acestep-v15-turbo` (music generation)
- LLM: `acestep-5Hz-lm-1.7B` (lyrics understanding)
- VAE: bundled with main model
- Total: ~10GB download

**Wan2.2**:
- Model: `Wan2.2-T2V-A14B` (text-to-video)
- Size: ~118GB download

## Model Persistence

Models are stored on a persistent EBS volume:

```
/opt/app/            → Application code (destroyed with instance)
/opt/models/         → Persistent EBS volume (PRESERVED)
  ├── acestep/       → ACE-Step models (~10GB)
  │   ├── acestep-v15-turbo/
  │   ├── acestep-5Hz-lm-1.7B/
  │   ├── vae/
  │   └── config.json
  └── Wan2.2-T2V-A14B/ → Wan2.2 model (~118GB)
```

## Quick Start

### 1. Provision Infrastructure

```bash
cd infra
./scripts/provision.sh
```

### 2. Start Applications

```bash
./scripts/start-apps.sh
```

This will:
- Install dependencies
- Download essential models
- Configure nginx
- Start nginx and ace-step-ui (always running)
- **NOT** start GPU services (on-demand only)

### 3. Start GPU Service When Needed

```bash
# On EC2 instance:
sudo systemctl start ace-step-1.5   # For music generation
# OR
sudo systemctl start wan22           # For video generation

# Or use the on-demand script:
/opt/scripts/gpu-on-demand.sh start-ace-step
```

## Service Management

### Always-Running Services

```bash
# Status
sudo systemctl status nginx
sudo systemctl status ace-step-ui

# Logs
tail -f /opt/logs/nginx-error.log
tail -f /opt/logs/ace-step-ui.log
```

### On-Demand GPU Services

```bash
# Start ACE-Step for music generation
sudo systemctl start ace-step-1.5
# Wait for models to load (~30s), then check health:
curl http://localhost:8001/health

# Start Wan2.2 for video generation
sudo systemctl start wan22

# Stop to free GPU memory
sudo systemctl stop ace-step-1.5
sudo systemctl stop wan22
```

### GPU On-Demand Script

```bash
# View current status
/opt/scripts/gpu-on-demand.sh status

# Start service (stops other if running)
/opt/scripts/gpu-on-demand.sh start-ace-step
/opt/scripts/gpu-on-demand.sh start-wan22

# Stop services
/opt/scripts/gpu-on-demand.sh stop-ace-step
/opt/scripts/gpu-on-demand.sh stop-wan22
```

## Configuration

### ACE-Step 1.5 Service

```ini
# /etc/systemd/system/ace-step-1.5.service
Environment="ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-1.7B"
Environment="ACESTEP_NO_INIT=true"          # Lazy load models
Environment="ACESTEP_OFFLOAD_TO_CPU=true"   # Free GPU when idle
Environment="ACESTEP_OFFLOAD_DIT_TO_CPU=true"
ExecStart=... acestep-api --host 127.0.0.1 --port 8001 --lm-model-path acestep-5Hz-lm-1.7B
```

### ACE-Step UI Environment

```bash
# /opt/app/music/ace-step-ui/.env
PORT=3001
NODE_ENV=production
ACESTEP_API_URL=http://127.0.0.1:8001
WAN22_API_URL=http://127.0.0.1:8080
GPU_ON_DEMAND=true
GPU_ON_DEMAND_SCRIPT=/opt/scripts/gpu-on-demand.sh
GPU_IDLE_TIMEOUT=300
```

## Monitoring

### SSH Access

```bash
ssh -i ~/babaNaTrue/ema-practice.pem ubuntu@$(cat .ec2_ip)
```

### Check Status

```bash
# Services
systemctl status nginx ace-step-ui ace-step-1.5 wan22

# GPU
nvidia-smi
watch -n 1 nvidia-smi

# On-demand status
/opt/scripts/gpu-on-demand.sh status
```

### Logs

```bash
tail -f /opt/logs/ace-step-1.5.log
tail -f /opt/logs/ace-step-1.5-error.log
tail -f /opt/logs/wan22.log
tail -f /opt/logs/ace-step-ui.log
```

## Common Operations

### Update Code

```bash
./scripts/update-code.sh
sudo systemctl restart ace-step-ui
```

### Restart Services

```bash
# Restart always-running services
sudo systemctl restart nginx ace-step-ui

# GPU services start on-demand
```

### Add New Model

```bash
# Download ACE-Step models
cd /opt/app/music/ACE-Step-1.5
ACESTEP_CHECKPOINTS_DIR=/opt/models/acestep uv run acestep-download --model <model-name>

# Wan2.2 requires manual huggingface-cli download
```

## Cost Considerations

- **g5.4xlarge**: ~$1.63/hour in us-east-1
- **EBS volume**: 200GB = ~$20/month
- **GPU services only run when needed** (saves compute costs)

## Troubleshooting

### GPU Services Won't Start

```bash
# Check if other GPU service is running
systemctl is-active ace-step-1.5 wan22

# Check GPU memory
nvidia-smi

# Check logs
journalctl -u ace-step-1.5 -n 50
journalctl -u wan22 -n 50
```

### Models Not Loading

```bash
# Check model directories
ls -la /opt/models/acestep/
ls -la /opt/models/Wan2.2-T2V-A14B/

# Check disk space
df -h
```

### Nginx Errors

```bash
# Test config
sudo nginx -t

# Check error log
tail -f /opt/logs/nginx-error.log
```

## Directory Structure

```
infra/
├── terraform/
│   ├── main.tf
│   ├── vpc.tf
│   ├── security.tf
│   ├── ec2.tf
│   └── ...
├── scripts/
│   ├── provision.sh
│   ├── start-apps.sh
│   ├── stop-apps.sh
│   ├── destroy.sh
│   ├── gpu-on-demand.sh      # On-demand GPU service management
│   └── gpu-resource-manager.sh
├── configs/
│   ├── nginx/
│   │   └── nginx.conf
│   └── systemd/
│       ├── ace-step-1.5.service
│       ├── wan22.service
│       └── ace-step-ui.service
└── .ec2_ip
```

## Credits

- **ACE-Step 1.5**: [ACE-Step/Ace-Step1.5](https://github.com/ace-step/ACE-Step-1.5)
- **Wan2.2**: [Wan-Video/Wan2.2](https://github.com/Wan-Video/Wan2.2)
- **ACE-Step UI**: Community frontend