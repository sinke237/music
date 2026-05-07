# =============================================================================
# Security Groups Configuration
# =============================================================================

resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-sg"
  description = "Security group for music generation EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-sg"
    Environment = var.environment
  }
}

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.ssh_allowed_cidrs
  security_group_id = aws_security_group.ec2_sg.id
  description        = "SSH access"
}

resource "aws_security_group_rule" "http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2_sg.id
  description        = "HTTP access via nginx"
}

resource "aws_security_group_rule" "https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2_sg.id
  description        = "HTTPS access via nginx"
}

resource "aws_security_group_rule" "ui_port" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2_sg.id
  description        = "ACE-Step UI (frontend)"
}

resource "aws_security_group_rule" "ace_step_internal" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_sg.id
  security_group_id        = aws_security_group.ec2_sg.id
  description              = "ACE-Step API (internal only)"
}

resource "aws_security_group_rule" "wan_internal" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_sg.id
  security_group_id        = aws_security_group.ec2_sg.id
  description               = "Wan2.2 API (internal only)"
}

# Inter-instance communication for distributed computing
resource "aws_security_group_rule" "inter_instance_all" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_sg.id
  security_group_id        = aws_security_group.ec2_sg.id
  description              = "Inter-instance communication (multi-node distributed)"
}

# MPI/NCCL communication ports for distributed training/inference
resource "aws_security_group_rule" "distributed_ports" {
  type                     = "ingress"
  from_port                = 29500
  to_port                  = 29600
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_sg.id
  security_group_id        = aws_security_group.ec2_sg.id
  description              = "Distributed training/inference ports (PyTorch Distributed)"
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2_sg.id
  description       = "Allow all outbound traffic"
}