# =============================================================================
# Outputs
# =============================================================================

# Single Instance Mode Outputs
output "instance_public_ip_single" {
  description = "Public IP of the single GPU instance (single instance mode)"
  value       = var.use_single_instance ? aws_eip.main_single[0].public_ip : ""
}

output "instance_private_ip_single" {
  description = "Private IP of the single GPU instance (single instance mode)"
  value       = var.use_single_instance ? aws_instance.gpu_instance_single[0].private_ip : ""
}

# Multi-Instance Mode Outputs
output "ace_instance_public_ips" {
  description = "Public IPs of ACE-Step instances (multi-instance mode)"
  value       = var.use_single_instance ? [] : aws_eip.ace[*].public_ip
}

output "ace_instance_private_ips" {
  description = "Private IPs of ACE-Step instances (multi-instance mode)"
  value       = var.use_single_instance ? [] : aws_instance.ace_instance[*].private_ip
}

output "wan_instance_public_ips" {
  description = "Public IPs of Wan2.2 instances (multi-instance mode)"
  value       = var.use_single_instance ? [] : aws_eip.wan[*].public_ip
}

output "wan_instance_private_ips" {
  description = "Private IPs of Wan2.2 instances (multi-instance mode)"
  value       = var.use_single_instance ? [] : aws_instance.wan_instance[*].private_ip
}

# Common Outputs
output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.ec2_sg.id
}

output "dns_name" {
  description = "DNS name for the application"
  value       = var.domain_name
}

output "ssh_command" {
  description = "Command to SSH into the primary instance"
  value       = var.use_single_instance ? "ssh -i ${var.private_key_path} ec2-user@${aws_eip.main_single[0].public_ip}" : "ssh -i ${var.private_key_path} ec2-user@${aws_eip.ace[0].public_ip}"
}

output "web_url" {
  description = "Web URL for the application"
  value       = var.use_single_instance ? "http://${aws_eip.main_single[0].public_ip}:3000" : "http://${aws_eip.ace[0].public_ip}:3000"
}

output "models_volume_id" {
  description = "ID of persistent models EBS volume"
  value       = aws_ebs_volume.models.id
}

output "models_volume_size" {
  description = "Size of persistent models EBS volume (GB)"
  value       = aws_ebs_volume.models.size
}

# Deployment mode information
output "deployment_mode" {
  description = "Deployment mode (single or multi-instance)"
  value       = var.use_single_instance ? "single" : "multi"
}

output "total_instance_count" {
  description = "Total number of instances deployed"
  value       = var.use_single_instance ? 1 : (var.ace_instance_count + var.wan_instance_count)
}

# Instance IDs for reference
output "single_instance_id" {
  description = "Instance ID (single instance mode)"
  value       = var.use_single_instance ? aws_instance.gpu_instance_single[0].id : ""
}

output "ace_instance_ids" {
  description = "ACE-Step instance IDs (multi-instance mode)"
  value       = var.use_single_instance ? [] : aws_instance.ace_instance[*].id
}

output "wan_instance_ids" {
  description = "Wan2.2 instance IDs (multi-instance mode)"
  value       = var.use_single_instance ? [] : aws_instance.wan_instance[*].id
}