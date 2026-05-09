# Music Generation Infrastructure

Production-ready AWS infrastructure for deploying AI music and video generation services.

## Overview

This infrastructure deploys services on a single EC2 GPU instance (g5.4xlarge) with 24GB VRAM:

| Service | Type | GPU | VRAM | Port | Description |
|---------|------|-----|------|------|-------------|
| ace-step-ui | Frontend | CPU only | - | 3000 | Spotify-like web interface |
| ace-step-1.5 | Backend | GPU 0 | ~24GB | 8001 | Music generation (ACE-Step) |
| wan2.2 | Backend | GPU 0 | ~12-14GB | 8080 | Video generation (Wan2.2-14B-GGUF via ComfyUI) |

## Instance Configuration

### g5.4xlarge

- **Instance Type**: g5.4xlarge
- **GPU**: 1 x NVIDIA A10G 24GB
- **vCPUs**: 16
- **Memory**: 64GB

### Model Configuration

**Wan2.2-14B-T2V-GGUF (Q6_K/Q8_0 variant)**:
- ~12-14GB VRAM for quantized model
- ComfyUI with tiled VAE decoding and model offloading
- CUDA 12.x + PyTorch 2.1+ with xformers support
- Fits comfortably in 24GB A10G with buffer for T5 encoder + VAE

## Model Persistence

Models are stored on a persistent EBS volume that survives infrastructure destruction.

### Storage Architecture

```
/opt/app/          → EC2 root volume (destroyed)
/opt/models/       → Persistent EBS volume (PRESERVED)
  ├── acestep/     → ACE-Step models (~5GB)
  └── Wan2.2/      → Wan2.2 models
```

### Destroy Options

```bash
# Destroy infrastructure BUT PRESERVE models (default)
./scripts/destroy.sh

# Destroy EVERYTHING including models
./scripts/destroy.sh --destroy-models
```

## Architecture

```
+-------------------------------------------------------------------+
|                        AWS Cloud                                   |
|  +-------------------------------------------------------------+  |
|  |                    VPC (10.0.0.0/16)                         |  |
|  |  +-------------------------------------------------------+ |  |
|  |  |              Public Subnet (10.0.1.0/24)               | |  |
|  |  |  +---------------------------------------------------+ | |  |
|  |  |  |     EC2 g5.4xlarge (1x A10G 24GB)                 | | |  |
|  |  |  |                                                   | | |  |
|  |  |  |  +--------------+    +------------------------+  | | |  |
|  |  |  |  |  Nginx (80)  |    |    ace-step-ui (3000)  |  | | |  |
|  |  |  |  |  API Gateway |    |    Frontend (CPU only) |  | | |  |
|  |  |  |  +------+------|    +-----------+------------+  | | |  |
|  |  |  |         |                           |          | | |  |
|  |  |  |         | /api/ace-step/*           |          | | |  |
|  |  |  |         +---------------------------+          | | |  |
|  |  |  |         | /api/wan22/*                         | | |  |
|  |  |  |  +------v--------------------------------------|-+ |  |
|  |  |  |  |         Backend Services                    | |  |  |
|  |  |  |  |  +----------------+   +------------------+ | |  |  |
|  |  |  |  |  | ace-step-1.5   |   |     wan2.2       | | |  |  |
|  |  |  |  |  | Port: 8001     |   |   Port: 8080     | | |  |  |
|  |  |  |  |  | GPU: 0         |   |   GPU: 0         | | |  |  |
|  |  |  |  |  +----------------+   +------------------+ | | |  |
|  |  |  |  +---------------------------------------------+ | |  |
|  |  |  +---------------------------------------------------+ |  |
|  |  +---------------------------------------------------------+  |
|  +-------------------------------------------------------------+  |
+-------------------------------------------------------------------+
```

## GPU Allocation

| Service | GPU | VRAM | Reasoning |
|---------|-----|------|-----------|
| ace-step-1.5 | GPU 0 | ~20-24GB | Music generation (turbo models for 24GB) |
| wan2.2 | GPU 0 | ~12-14GB | Wan2.2-14B-GGUF (quantized) |

GPU isolation is enforced via `CUDA_VISIBLE_DEVICES`:

- **ACE-Step-1.5**: `CUDA_VISIBLE_DEVICES=0`
- **Wan2.2**: `CUDA_VISIBLE_DEVICES=0` (sequential execution or model offloading)

## Prerequisites

### Local Machine

- **Terraform** >= 1.5.0
- **AWS CLI** configured with credentials
- **SSH Key** at `~/babaNaTrue/ema-practice.pem`

### AWS Requirements

- AWS account with g5.4xlarge quota
- SSH key pair uploaded to AWS (public key at `infra/keys/ema-practice.pub`)
- Domain name (optional, for HTTPS)

## Quick Start

### 1. Provision Infrastructure

```bash
cd infra
TFVARS_FILE=terraform-g5.tfvars ./scripts/provision.sh
```

This will:
- Create VPC, subnets, security groups
- Launch EC2 g5.4xlarge instance
- Allocate Elastic IP
- Clone repository to EC2
- Save EC2 IP to `.ec2_ip`

### 2. Start Applications

```bash
./scripts/start-apps.sh
```

### 3. Setup SSL (Optional)

```bash
./scripts/setup-ssl-dns.sh
```

## Directory Structure

```
infra/
+-- terraform/
|   +-- main.tf
|   +-- vpc.tf
|   +-- security.tf
|   +-- iam.tf
|   +-- ec2.tf
|   +-- user_data_single.sh
|   +-- variables.tf
|   +-- outputs.tf
|   +-- terraform.tfvars          # Default (g5.4xlarge)
|   +-- terraform-g5.tfvars      # g5.4xlarge specific
|
+-- scripts/
|   +-- provision.sh
|   +-- start-apps.sh
|   +-- stop-apps.sh
|   +-- update-code.sh
|   +-- restart-apps.sh
|   +-- destroy.sh
|   +-- setup-ssl-dns.sh
|
+-- configs/
|   +-- nginx/
|   |   +-- nginx.conf
|   +-- systemd/
|   |   +-- ace-step-1.5.service
|   |   +-- wan22.service
|   |   +-- ace-step-ui.service
|   +-- env/
|       +-- ace-step-1.5.env
|       +-- wan22.env
|       +-- ace-step-ui.env
|
+-- keys/
|   +-- ema-practice.pub
|
+-- aws-credentials.env         # (gitignored)
+-- .ec2_ip                     # (created by provision.sh)
+-- README.md
```

## Configuration

### Environment Variables

Edit `.env` files in `configs/env/`:

```bash
# ACE-Step-1.5 (turbo models for 24GB VRAM)
CUDA_VISIBLE_DEVICES=0
ACESTEP_CONFIG_PATH=acestep-v15-turbo
ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-1.7B

# Wan2.2 (GGUF quantized model)
CUDA_VISIBLE_DEVICES=0
MODEL=wan2.2-14b-t2v-gguf-q6

# ACE-Step UI
PORT=3001
ACESTEP_API_URL=http://127.0.0.1:8001
```

## Monitoring

### SSH into Instance

```bash
ssh -i ~/babaNaTrue/ema-practice.pem ec2-user@$(cat .ec2_ip)
```

### Check Service Status

```bash
sudo systemctl status ace-step-1.5
sudo systemctl status wan22
sudo systemctl status ace-step-ui
sudo systemctl status nginx
```

### View Logs

```bash
tail -f /opt/logs/ace-step-1.5.log
tail -f /opt/logs/wan22.log
tail -f /opt/logs/ace-step-ui.log
```

### GPU Status

```bash
nvidia-smi
watch -n 1 nvidia-smi
```

## Common Operations

### Update Code

```bash
./scripts/update-code.sh
./scripts/restart-apps.sh
```

### Restart Services

```bash
./scripts/restart-apps.sh
```

### Stop/Start Services

```bash
./scripts/stop-apps.sh
./scripts/start-apps.sh
```

### Destroy Infrastructure

```bash
./scripts/destroy.sh
```

## Cost Considerations

- **g5.4xlarge**: ~$1.63/hour in us-east-1
- **EBS volume**: 500GB = ~$50/month
- **Elastic IP**: Free when attached to running instance
- **Data transfer**: Variable based on usage

## License

This infrastructure configuration is provided as-is for deploying open-source AI models.

## Credits

- **ACE-Step 1.5**: [ACE-Step/Ace-Step1.5](https://github.com/ace-step/ACE-Step-1.5)
- **Wan2.2**: [Wan-Video/Wan2.2](https://github.com/Wan-Video/Wan2.2)
- **ACE-Step UI**: Community frontend