# =============================================================================
# IAM Configuration
# =============================================================================

data "aws_iam_role" "existing_ec2_role" {
  count = var.import_existing_iam_role ? 1 : 0
  name  = "${var.project_name}-ec2-role"
}

data "aws_iam_instance_profile" "existing_ec2_profile" {
  count = var.import_existing_instance_profile ? 1 : 0
  name  = "${var.project_name}-ec2-profile"
}

resource "aws_iam_role" "ec2_role" {
  count = var.import_existing_iam_role ? 0 : 1
  name  = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ec2-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "ec2_ssm_policy" {
  count = var.import_existing_iam_role ? 0 : 1
  name  = "${var.project_name}-ec2-ssm-policy"
  role  = local.role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = var.s3_bucket_arn != "" ? var.s3_bucket_arn : "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  count      = var.import_existing_iam_role ? 0 : 1
  role       = local.role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  count = var.import_existing_instance_profile ? 0 : 1
  name  = "${var.project_name}-ec2-profile"
  role  = local.role_name

  tags = {
    Name        = "${var.project_name}-ec2-profile"
    Environment = var.environment
  }
}

locals {
  role_name    = var.import_existing_iam_role ? data.aws_iam_role.existing_ec2_role[0].name : aws_iam_role.ec2_role[0].name
  role_arn     = var.import_existing_iam_role ? data.aws_iam_role.existing_ec2_role[0].arn : aws_iam_role.ec2_role[0].arn
  profile_name = var.import_existing_instance_profile ? data.aws_iam_instance_profile.existing_ec2_profile[0].name : aws_iam_instance_profile.ec2_profile[0].name
  profile_arn  = var.import_existing_instance_profile ? data.aws_iam_instance_profile.existing_ec2_profile[0].arn : aws_iam_instance_profile.ec2_profile[0].arn
}