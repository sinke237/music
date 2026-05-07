# =============================================================================
# Key Pair for SSH Access
# =============================================================================

resource "aws_key_pair" "deployer" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)

  tags = {
    Name        = var.key_name
    Environment = var.environment
  }
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
}

# =============================================================================
# Single Instance Deployment (p4de.24xlarge mode)
# =============================================================================

resource "aws_instance" "gpu_instance_single" {
  count = var.use_single_instance ? 1 : 0

  ami                    = data.aws_ami.gpu_ami.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

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
# Multi-Instance Deployment (g5.48xlarge mode)
# =============================================================================

resource "aws_instance" "ace_instance" {
  count = var.use_single_instance ? 0 : var.ace_instance_count

  ami                    = data.aws_ami.gpu_ami.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 200
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data_ace.sh", {
    project_name      = var.project_name
    repository_url    = var.repository_url
    repository_branch = var.repository_branch
    instance_index     = count.index
    total_ace_instances = var.ace_instance_count
  }))

  tags = {
    Name        = "${var.project_name}-ace-${count.index + 1}"
    Environment = var.environment
    Role        = "ace-step"
    Index       = count.index
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "wan_instance" {
  count = var.use_single_instance ? 0 : var.wan_instance_count

  ami                    = data.aws_ami.gpu_ami.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 200
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data_wan.sh", {
    project_name      = var.project_name
    repository_url    = var.repository_url
    repository_branch = var.repository_branch
    instance_index     = count.index
    total_wan_instances = var.wan_instance_count
  }))

  tags = {
    Name        = "${var.project_name}-wan-${count.index + 1}"
    Environment = var.environment
    Role        = "wan"
    Index       = count.index
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# Attach Models Volume to Primary Instance
# =============================================================================

resource "aws_volume_attachment" "models_single" {
  count = var.use_single_instance ? 1 : 0

  device_name  = "/dev/sdb"
  volume_id    = aws_ebs_volume.models.id
  instance_id  = aws_instance.gpu_instance_single[0].id
}

resource "aws_volume_attachment" "models_ace" {
  count = var.use_single_instance ? 0 : 1

  device_name  = "/dev/sdb"
  volume_id    = aws_ebs_volume.models.id
  instance_id  = aws_instance.ace_instance[0].id
}

# =============================================================================
# Elastic IPs for All Instances
# =============================================================================

resource "aws_eip" "main_single" {
  count  = var.use_single_instance ? 1 : 0
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-eip-single"
    Environment = var.environment
  }
}

resource "aws_eip" "ace" {
  count  = var.use_single_instance ? 0 : var.ace_instance_count
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-eip-ace-${count.index + 1}"
    Environment = var.environment
    Role        = "ace-step"
  }
}

resource "aws_eip" "wan" {
  count  = var.use_single_instance ? 0 : var.wan_instance_count
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-eip-wan-${count.index + 1}"
    Environment = var.environment
    Role        = "wan"
  }
}

# =============================================================================
# EIP Associations
# =============================================================================

resource "aws_eip_association" "main_single" {
  count         = var.use_single_instance ? 1 : 0
  instance_id   = aws_instance.gpu_instance_single[0].id
  allocation_id = aws_eip.main_single[0].id
}

resource "aws_eip_association" "ace" {
  count         = var.use_single_instance ? 0 : var.ace_instance_count
  instance_id   = aws_instance.ace_instance[count.index].id
  allocation_id = aws_eip.ace[count.index].id
}

resource "aws_eip_association" "wan" {
  count         = var.use_single_instance ? 0 : var.wan_instance_count
  instance_id   = aws_instance.wan_instance[count.index].id
  allocation_id = aws_eip.wan[count.index].id
}