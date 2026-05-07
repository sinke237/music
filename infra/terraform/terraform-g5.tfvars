# =============================================================================
# Terraform Variables Override - Multi-Instance g5.48xlarge Mode
# =============================================================================

aws_region = "eu-central-1"
project_name = "ema-practice"

# Deployment mode
use_single_instance = false

# Instance counts (for multi-instance mode)
# g5.12xlarge: 4x A10G 24GB GPUs per instance (96GB VRAM)
# ACE-Step: ~30GB VRAM needed - fits on 1 instance with turbo models
# Wan2.2: ~560GB needed - requires 6 instances (576GB total)
ace_instance_count = 1
wan_instance_count = 6

# Instance configuration
instance_type = "g5.12xlarge"
ami_id = "ami-0b3eebcd4111d5b5d"
key_name = "ema-practice"
private_key_path = "$HOME/babaNaTrue/ema-practice.pem"

# Networking
vpc_cidr = "10.0.0.0/16"
ssh_allowed_cidrs = ["0.0.0.0/0"]

# Domain and repository
domain_name = "suno.enowsinke.com"
repository_url = "git@github.com:sinke237/music.git"
repository_branch = "main"

# Storage
models_volume_size = 1000