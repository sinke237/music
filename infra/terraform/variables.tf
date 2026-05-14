# =============================================================================
# Variables
# =============================================================================

# AWS Region
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

# Instance Configuration
variable "instance_type" {
  description = "EC2 instance type for GPU instance"
  type        = string
  default     = "g5.4xlarge"
}

variable "ami_id" {
  description = "AMI ID for GPU instance (Deep Learning AMI GPU CUDA)"
  type        = string
  default     = "ami-0b3eebcd4111d5b5d"
}



variable "models_volume_size" {
  description = "Size in GB for persistent models volume (NOT destroyed by default)"
  type        = number
  default     = 1000
}

variable "use_single_instance" {
  description = "Deploy all services on a single instance"
  type        = bool
  default     = true
}

# VPC Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# Project Tags
variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
  default     = "music-generation"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

# Key Pair
variable "key_name" {
  description = "Name of the SSH key pair"
  type        = string
  default     = "ema-practice"
}

variable "public_key_path" {
  description = "Path to public key file"
  type        = string
  default     = "../keys/ema-practice.pub"
}

variable "private_key_path" {
  description = "Path to private key file (local)"
  type        = string
  default     = "~/babaNaTrue/ema-practice.pem"
}

# Domain and Repository
variable "domain_name" {
  description = "Domain name for the application"
  type        = string
  default     = "suno.enowsinke.com"
}

variable "repository_url" {
  description = "Git repository URL"
  type        = string
  default     = "git@github.com:sinke237/music.git"
}

variable "repository_branch" {
  description = "Git repository branch"
  type        = string
  default     = "main"
}

# Security
variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Optional S3 for model storage
variable "s3_bucket_arn" {
  description = "S3 bucket ARN for model storage (optional)"
  type        = string
  default     = ""
}

# Import existing resources (set to true if resources already exist in AWS)
variable "import_existing_key_pair" {
  description = "Set to true if key pair already exists in AWS"
  type        = bool
  default     = false
}

variable "import_existing_iam_role" {
  description = "Set to true if IAM role already exists in AWS"
  type        = bool
  default     = false
}

variable "import_existing_instance_profile" {
  description = "Set to true if IAM instance profile already exists in AWS"
  type        = bool
  default     = false
}