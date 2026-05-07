# Music Generation Infrastructure

Production-ready AWS infrastructure for deploying AI music and video generation services.

## 🎯 Overview

This infrastructure deploys **3 services** on a single EC2 GPU instance (p4de.24xlarge):

| Service | Type | GPU | VRAM | Port | Description |
|---------|------|-----|------|------|-------------|
| **ace-step-ui** | Frontend | CPU only | - | 3000 | Spotify-like web interface |
| **ace-step-1.5** | Backend | GPU 0 | 80GB | 8001 | Music generation (ACE-Step) |
| **wan2.2** | Backend | GPUs 1-7 | 560GB | 8080 | Video generation (Wan2.2) |

## 🎨 Model Configuration

### ACE-Step-1.5 (Best Quality)

Using the highest quality models by default:
- **DiT Model**: `acestep-v15-xl-sft` (4B parameters)
- **LM Model**: `acestep-5Hz-lm-4B` (4B parameters)
- **Quality**: Maximum
- **VRAM**: ~20-40GB (plenty of headroom on A100 80GB)

To change model quality, edit `infra/configs/env/ace-step-1.5.env`:

```bash
# Best Quality (Default)
ACESTEP_CONFIG_PATH=acestep-v15-xl-sft
ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-4B

# Turbo Mode (Faster, still excellent)
ACESTEP_CONFIG_PATH=acestep-v15-xl-turbo
ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-1.7B

# Standard Mode (Fast, good quality)
ACESTEP_CONFIG_PATH=acestep-v15-turbo
ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-1.7B
```

### Wan2.2

- **Model**: `Wan2.2-T2V-A14B` (MoE, 27B parameters)
- **Quality**: Maximum
- **VRAM**: Distributed across GPUs 1-7 (560GB total)

## 💾 Model Persistence

**Models are stored on a persistent EBS volume that survives infrastructure destruction!**

### Storage Architecture

```
/opt/app/          → EC2 root volume (destroyed)
/opt/models/       → Persistent EBS volume (PRESERVED)
  ├── acestep/     → ACE-Step models (~5GB)
  └── Wan2.2-T2V-A14B/ → Wan2.2 models (~40GB)
```

### Benefits

- ✅ **Models downloaded ONCE** (~50GB total)
- ✅ **Survives infrastructure destroy**
- ✅ **Instant redeployment** (no re-download)
- ✅ **~1-2 hours saved** on each deployment

### Destroy Options

```bash
# Destroy infrastructure BUT PRESERVE models (default)
./scripts/destroy.sh

# Destroy EVERYTHING including models
./scripts/destroy.sh --destroy-models
```

When you run `./scripts/provision.sh` again:
1. Terraform creates new EC2 instance
2. **Automatically reattaches** existing models volume
3. Models are available immediately at `/opt/models`
4. No download required!

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS Cloud                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    VPC (10.0.0.0/16)                       │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │              Public Subnet (10.0.1.0/24)            │  │  │
│  │  │  ┌────────────────────────────────────────────────┐ │  │  │
│  │  │  │     EC2 p4de.24xlarge (8× A100 80GB)           │ │  │  │
│  │  │  │                                                 │ │  │  │
│  │  │  │  ┌──────────────┐    ┌──────────────────────┐ │ │  │  │
│  │  │  │  │  Nginx (80)  │    │  ace-step-ui (3000)  │ │ │  │  │
│  │  │  │  │  API Gateway │    │  Frontend (CPU only) │ │ │  │  │
│  │  │  │  └──────┬───────┘    └──────────┬───────────┘ │ │  │  │
│  │  │  │         │                       │             │ │  │  │
│  │  │  │         │ /api/ace-step/*       │             │ │  │  │
│  │  │  │         └───────────────────────┼─────────────┘ │  │  │
│  │  │  │                                   │              │  │  │
│  │  │  │         ┌─────────────────────────┘              │  │  │
│  │  │  │         │ /api/wan22/*                           │  │  │
│  │  │  │         │                                        │  │  │
│  │  │  │  ┌──────▼─────────────────────────────────────────▼ │  │
│  │  │  │  │         Backend Services                        │ │  │  │
│  │  │  │  │  ┌────────────────┐   ┌──────────────────────┐ │ │  │  │
│  │  │  │  │  │ ace-step-1.5   │   │      wan2.2          │ │ │  │  │
│  │  │  │  │  │ Port: 8001     │   │   Port: 8080         │ │ │  │  │
│  │  │  │  │  │ GPU: 0         │   │   GPU: 1-7            │ │ │  │  │
│  │  │  │  │  │ VRAM: 80GB     │   │   VRAM: 560GB        │ │ │  │  │
│  │  │  │  │  └────────────────┘   └──────────────────────┘ │ │  │  │
│  │  │  │  └─────────────────────────────────────────────────┘ │  │  │
│  │  │  └────────────────────────────────────────────────────┘ │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## 🎮 GPU Allocation

### Deployment Modes

This infrastructure supports **two deployment modes**:

#### 1. Single Instance Mode (p4de.24xlarge) - Default
All services on one powerful instance with 8× A100 80GB GPUs. Use when p4de quota is available.

#### 2. Multi-Instance Mode (g5.48xlarge)
Multiple instances with 4× g5.48xlarge (each has 8× A10G 24GB GPUs). Use for broader availability and lower cost.

| Mode | Instance Type | Instances | GPUs | VRAM/Instance | Total VRAM | Cost/Hour |
|------|---------------|-----------|------|---------------|------------|-----------|
| Single | p4de.24xlarge | 1 | 8× A100 80GB | 640GB | 640GB | ~$32 |
| Multi | g5.48xlarge | 4 | 8× A10G 24GB each | 192GB each | 768GB | ~$64 (4×$16) |

### Single Instance Mode (p4de.24xlarge)

### p4de.24xlarge Instance
- **Instance Type**: p4de.24xlarge
- **GPUs**: 8 × NVIDIA A100 80GB
- **Total VRAM**: 640GB
- **vCPUs**: 96
- **Memory**: 1,152GB

### GPU Memory Requirements

#### ACE-Step-1.5 (GPU 0)

| Model | Parameters | Weights | Activations | Total VRAM |
|-------|-----------|---------|-------------|------------|
| `acestep-v15-xl-sft` + `acestep-5Hz-lm-4B` | 4B + 4B | ~17GB | ~5-10GB | **~25-30GB** |
| `acestep-v15-xl-turbo` + `acestep-5Hz-lm-1.7B` | 4B + 1.7B | ~14GB | ~3-8GB | **~20-25GB** |
| `acestep-v15-turbo` + `acestep-5Hz-lm-1.7B` | 2B + 1.7B | ~8GB | ~2-5GB | **~15-20GB** |

**GPU 0 has 80GB available → Plenty of headroom for all configurations!**

#### Wan2.2 (GPUs 1-7)

| Mode | Total VRAM | Distributed Across |
|------|-----------|---------------------|
| Single GPU | ~80GB | 1 GPU |
| Multi-GPU FSDP | ~40-80GB | 4-8 GPUs |
| **Available** | **560GB** | **7 GPUs (80GB each)** |

**Wan2.2 has 560GB available → Exceeds 50GB requirement massively!**

### GPU Mapping

| Service | GPU Assignment | VRAM | Reasoning |
|---------|---------------|------|-----------|
| **ace-step-1.5** | GPU 0 | 80GB | Music generation needs single GPU; best quality models use ~30GB max |
| **wan2.2** | GPUs 1-7 | 560GB total | Video generation uses distributed inference via FSDP + DeepSpeed Ulysses |

### GPU Isolation

GPU isolation is enforced via `CUDA_VISIBLE_DEVICES` environment variable:

- **ACE-Step-1.5**: `CUDA_VISIBLE_DEVICES=0`
- **Wan2.2**: `CUDA_VISIBLE_DEVICES=1,2,3,4,5,6,7`
- **ace-step-ui**: No GPU access (CPU only)

This ensures:
- No GPU contention between services
- Wan2.2 has access to 560GB+ VRAM (>50GB requirement met)
- Each service has dedicated GPU resources

---

### Multi-Instance Mode (g5.48xlarge)

When p4de instances are unavailable, use g5.48xlarge multi-instance deployment:

#### Instance Allocation

| Instance | Role | GPUs | VRAM | Services |
|----------|------|------|------|----------|
| **ace-1** | Primary + Frontend | 8× A10G 24GB | 192GB | ACE-Step 1.5 + UI + Nginx |
| **wan-1** | Distributed Node | 8× A10G 24GB | 192GB | Wan2.2 (Node 0, Rank 0) |
| **wan-2** | Distributed Node | 8× A10G 24GB | 192GB | Wan2.2 (Node 1, Rank 1) |
| **wan-3** | Distributed Node | 8× A10G 24GB | 192GB | Wan2.2 (Node 2, Rank 2) |

**Total: 4 instances, 32 GPUs, 768GB VRAM**

#### GPU Memory Requirements (A10G 24GB GPUs)

Since A10G GPUs have less VRAM than A100, model configuration must be adjusted:

##### ACE-Step-1.5 (Instance ace-1)
- Use **turbo models** (auto-detected by GPU VRAM)
- `acestep-v15-turbo` + `acestep-5Hz-lm-1.7B`: ~15-20GB per GPU
- Enable model offload for XL models if needed

##### Wan2.2 Distributed (Instances wan-1, wan-2, wan-3)
- Uses FSDP + DeepSpeed Ulysses for multi-node inference
- TotalVRAM across 3 instances: 576GB (exceeds 560GB requirement)
- Each GPU processes a portion of the model
- Master node coordination via network

#### Network Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS Cloud                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                VPC (10.0.0.0/16)                          │  │
│  │  ┌─────────────────────────────────────────────────────┐ │  │
│  │  │          Public Subnet (10.0.1.0/24)                │ │  │
│  │  │                                                      │ │  │
│  │  │  ┌──────────────┐  ┌────────────────────────────┐  │ │  │
│  │  │  │  ace-1       │  │  wan-1  wan-2  wan-3      │  │ │  │
│  │  │  │  Primary     │  │  Distributed  Wan2.2     │  │ │  │
│  │  │  │              │  │                          │  │ │  │
│  │  │  │  nginx:80    │  │  FSDP + DeepSpeed        │  │ │  │
│  │  │  │  UI:3000     │  │  Inter-node comm         │  │ │  │
│  │  │  │  ace:8001    │  │                          │  │ │  │
│  │  │  └──────────────┘  └────────────────────────────┘  │ │  │
│  │  └─────────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

#### Model Storage

- **Primary ACE instance** mounts the persistent EBS volume
- **WAN instances** access models via NFS share from primary
  
#### Deploying Multi-Instance Mode

```bash
# Use the G5 deployment script
cd infra
./scripts/provision-g5.sh

# This creates 4 instances:
# - 1 ACE-Step instance (primary + frontend)
# - 3 Wan2.2 instances (distributed inference)
```

#### Comparison: Single vs Multi-Instance

| Aspect | Single (p4de) | Multi (g5.48xlarge) |
|--------|---------------|---------------------|
| Instances | 1 | 4 |
| Provisioning Speed | Slow (46+ min) | Faster (~15 min each) |
| Availability | Limited quota | Broader availability |
| Cost/Hour | ~$32 | ~$64 (4×$16) |
| Latency | Lower (local GPU) | Higher (network) |
| Complexity | Simple | Complex (network, NFS) |
| Fault Tolerance | Single point | Distributed |

## 📦 Prerequisites

### Local Machine
- **Terraform** >= 1.5.0
- **AWS CLI** configured with credentials
- **SSH Key** at `~/babaNaTrue/ema-practice.pem`

### AWS Requirements
- AWS account with GPU instance quota
- SSH key pair uploaded to AWS (public key at `infra/keys/ema-practice.pub`)
- Domain name (optional, for HTTPS)

### Credentials
- AWS credentials in `infra/aws-credentials.env` (gitignored)
- SSH private key at `~/babaNaTrue/ema-practice.pem`

## ⚡ Idempotency

**All scripts are designed to be idempotent** - safe to run multiple times.

- **`provision.sh`**: Will not recreate infrastructure if it already exists
- **`start-apps.sh`**: Will skip already-installed dependencies and running services
- **`setup-ssl-dns.sh`**: Will not create new SSL certificates if one already exists
- **`update-code.sh`**: Uses git stash/pop to preserve local changes
- **`restart-apps.sh`**: Gracefully restarts only running services
- **`stop-apps.sh`**: Will not fail if services are already stopped
- **`destroy.sh`**: Always removes all resources (use with caution)

**Benefits:**
- No duplicate SSL certificates
- No failed "already running" errors
- Safe to re-run after network interruptions
- Easy to recover from partial failures

## 🚀 Quick Start

Choose your deployment mode:
- **Single Instance (p4de)**: Use `provision.sh` - All services on one GPU instance
- **Multi-Instance (g5)**: Use `provision-g5.sh` - Services distributed across multiple instances

### 1. Provision Infrastructure

#### Option A: Single Instance (p4de.24xlarge)

```bash
cd infra
./scripts/provision.sh
```

This will:
- Create VPC, subnets, security groups
- Launch EC2 p4de.24xlarge instance
- Allocate Elastic IP
- Clone repository to EC2
- Save EC2 IP to `.ec2_ip`

#### Option B: Multi-Instance (g5.48xlarge)

```bash
cd infra
./scripts/provision-g5.sh
```

This will:
- Create VPC, subnets, security groups with inter-instance communication
- Launch 4 g5.48xlarge instances (1 ACE, 3 WAN)
- Allocate Elastic IPs for all instances
- Clone repository to each instance
- Save instance IPs to `.ec2_ip`

### 2. Start Applications

```bash
./scripts/start-apps.sh
```

This will:
- Install all dependencies
- Download models
- Configure nginx
- Start all services

### 3. Setup SSL (Optional)

```bash
./scripts/setup-ssl-dns.sh
```

This will:
- Configure DNS
- Obtain Let's Encrypt SSL certificate
- Configure nginx for HTTPS

## 📁 Directory Structure

```
infra/
├── terraform/                  # Terraform configuration
│   ├── main.tf                 # Variables and outputs
│   ├── vpc.tf                  # VPC and networking
│   ├── security.tf             # Security groups
│   ├── iam.tf                  # IAM roles and policies
│   ├── ec2.tf                  # EC2 instance and EIP
│   ├── user_data.sh            # EC2 initialization script
│   └── variables.tf            # (consolidated into main.tf)
│
├── scripts/                    # Deployment scripts
│   ├── provision.sh            # Create infrastructure
│   ├── start-apps.sh           # Start all services
│   ├── stop-apps.sh            # Stop all services
│   ├── update-code.sh          # Update code from git
│   ├── restart-apps.sh         # Restart services
│   ├── destroy.sh              # Destroy infrastructure
│   └── setup-ssl-dns.sh        # Configure SSL/DNS
│
├── configs/                    # Configuration files
│   ├── nginx/
│   │   └── nginx.conf          # Nginx API gateway config
│   ├── systemd/
│   │   ├── ace-step-1.5.service
│   │   ├── wan22.service
│   │   ├── ace-step-ui.service
│   │   └── nginx.service
│   └── env/
│       ├── ace-step-1.5.env
│       ├── wan22.env
│       └── ace-step-ui.env
│
├── keys/                       # SSH keys
│   └── ema-practice.pub        # Public key (uploaded to AWS)
│
├── aws-credentials.env         # AWS credentials (gitignored)
├── .ec2_ip                     # EC2 IP (created by provision.sh)
└── README.md                   # This file
```

## 🔧 Configuration

### Environment Variables

Edit the `.env` files in `configs/env/`:

```bash
# ACE-Step-1.5
CUDA_VISIBLE_DEVICES=0
ACESTEP_CONFIG_PATH=acestep-v15-turbo
ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-1.7B

# Wan2.2
CUDA_VISIBLE_DEVICES=1,2,3,4,5,6,7
DEFAULT_MODEL=t2v-A14B

# ACE-Step UI
PORT=3001
ACESTEP_API_URL=http://127.0.0.1:8001
```

### GPU Configuration

To modify GPU allocation, edit the systemd service files:

```bash
# For ACE-Step-1.5 (configs/systemd/ace-step-1.5.service)
Environment="CUDA_VISIBLE_DEVICES=0"

# For Wan2.2 (configs/systemd/wan22.service)
Environment="CUDA_VISIBLE_DEVICES=1,2,3,4,5,6,7"
```

### Model Selection

#### ACE-Step-1.5 Models

| Model | Parameters | VRAM Required | Quality |
|-------|-----------|---------------|---------|
| `acestep-v15-turbo` | 2B | ~20GB | Fast |
| `acestep-v15-xl-turbo` | 4B | ~40GB | Better |
| `acestep-v15-xl-sft` | 4B | ~40GB | Best |

#### Wan2.2 Models

| Model | Task | VRAM Required |
|-------|------|---------------|
| `t2v-A14B` | Text-to-Video MoE | ~80GB (distributed) |
| `i2v-A14B` | Image-to-Video MoE | ~80GB (distributed) |
| `ti2v-5B` | Text/Image-to-Video | ~24GB |

## 🌐 API Gateway Routing

All traffic goes through Nginx API gateway at `suno.enowsinke.com`:

```
suno.enowsinke.com/
├── /                    → ACE-Step UI (React app)
├── /api/ace-step/*      → ACE-Step 1.5 API (port 8001)
├── /api/wan22/*         → Wan2.2 API (port 8080)
└── /health              → Health check
```

**No CORS issues** - all requests go through thesame domain.

## 🔐 Security

### Security Groups

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | All IPs (restrict in production) |
| 80 | HTTP | All IPs |
| 443 | HTTPS | All IPs |
| 3000 | UI | All IPs (via Nginx) |
| 8001 | ACE-Step API | Internal only |
| 8080 | Wan2.2 API | Internal only |

### Secrets Management

- AWS credentials: `aws-credentials.env` (gitignored)
- SSH key: `~/babaNaTrue/ema-practice.pem` (local)
- No secrets in Terraform or systemd files

## 📊 Monitoring

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
tail -f /var/log/nginx/music-access.log
```

### GPU Status

```bash
nvidia-smi
watch -n 1 nvidia-smi
```

## 🔄 Common Operations

### Update Code

```bash
./scripts/update-code.sh
./scripts/restart-apps.sh
```

### Restart Services

```bash
./scripts/restart-apps.sh
```

### Stop Services

```bash
./scripts/stop-apps.sh
```

### Start Services

```bash
./scripts/start-apps.sh
```

### Destroy Infrastructure

```bash
./scripts/destroy.sh
```

**⚠️ WARNING**: This will destroy ALL AWS resources (EC2, VPC, EIP, etc.)

## 🐛 Troubleshooting

### Service Won't Start

1. Check logs: `sudo journalctl -u ace-step-1.5 -f`
2. Verify GPU: `nvidia-smi`
3. Check CUDA: `CUDA_VISIBLE_DEVICES=0 python -c "import torch; print(torch.cuda.is_available())"`

### GPU Memory Issues

1. Check VRAM usage: `nvidia-smi`
2. Reduce model size in `.env` files
3. Enable model offloading: `OFFLOAD_MODEL=true`

### CORS Errors

- All requests should go throughNginx API gateway
- Access APIs via `/api/ace-step/` and `/api/wan22/`
- Never access backend ports directly

### Nginx Errors

```bash
sudo nginx -t                    # Test configuration
sudo systemctl restart nginx     # Restart nginx
tail -f /var/log/nginx/error.log # View errors
```

## 📝 Notes

### Model Downloads

- **ACE-Step models** are downloaded automatically on first run (~5GB)
- **Wan2.2 models** must be downloaded manually or via script (~40GB)

### Cost Considerations

- **p4de.24xlarge**: ~$32/hour in us-east-1
- **EBS volumes**: 500GB × 2 = ~$50/month
- **Elastic IP**: Free when attached to running instance
- **Data transfer**: Variable based on usage

### Performance

- **ACE-Step-1.5**: ~2s per song on A100
- **Wan2.2**: ~1-10 minutes per video (depends on resolution/length)

## 📄 License

This infrastructure configuration is provided as-isfor deploying open-source AI models.

## 🙏 Credits

- **ACE-Step 1.5**: [ACE-Step/Ace-Step1.5](https://github.com/ace-step/ACE-Step-1.5)
- **Wan2.2**: [Wan-Video/Wan2.2](https://github.com/Wan-Video/Wan2.2)
- **ACE-Step UI**: Community frontend