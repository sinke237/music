# =============================================================================
# Key Pair for SSH Access
# =============================================================================

data "aws_key_pair" "existing" {
  count = var.import_existing_key_pair ? 1 : 0

  key_name           = var.key_name
  include_public_key = false
}

resource "aws_key_pair" "deployer" {
  count = var.import_existing_key_pair ? 0 : 1

  key_name   = var.key_name
  public_key = file("${path.root}/${var.public_key_path}")

  tags = {
    Name        = var.key_name
    Environment = var.environment
  }
}

locals {
  key_name = var.import_existing_key_pair ? data.aws_key_pair.existing[0].key_name : aws_key_pair.deployer[0].key_name
}

# =============================================================================
# Persistent EBS Volume for Models (NOT destroyed by default)
# =============================================================================

resource "aws_ebs_volume" "models" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.models_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${var.project_name}-models-volume"
    Environment = var.environment
    Persistent  = "true"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# =============================================================================
# Single Instance Deployment (g5.4xlarge - 24GB VRAM)
# =============================================================================

resource "aws_instance" "gpu_instance" {
  ami                    = data.aws_ami.gpu_ami.id
  instance_type          = var.instance_type
  key_name               = local.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = local.profile_name

  root_block_device {
    volume_size           = 200
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data_single.sh", {
    project_name      = var.project_name
    repository_url    = var.repository_url
    repository_branch = var.repository_branch
  }))

  tags = {
    Name        = "${var.project_name}-gpu-instance"
    Environment = var.environment
    Role        = "single"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# Attach Models Volume to Instance
# =============================================================================

resource "aws_volume_attachment" "models" {
  device_name   = "/dev/sdf"
  volume_id     = aws_ebs_volume.models.id
  instance_id   = aws_instance.gpu_instance.id
  force_detach  = true
  stop_instance_before_detaching = true

  depends_on = [aws_instance.gpu_instance]

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# Elastic IP
# =============================================================================

resource "aws_eip" "main" {
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-eip"
    Environment = var.environment
  }
}

# =============================================================================
# EIP Association
# =============================================================================

resource "aws_eip_association" "main" {
  instance_id   = aws_instance.gpu_instance.id
  allocation_id = aws_eip.main.id
}