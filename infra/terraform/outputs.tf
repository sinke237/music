# =============================================================================
# Outputs
# =============================================================================

output "instance_public_ip" {
  description = "Public IP of the GPU instance"
  value       = aws_eip.main.public_ip
}

output "instance_private_ip" {
  description = "Private IP of the GPU instance"
  value       = aws_instance.gpu_instance.private_ip
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.ec2_sg.id
}

output "dns_name" {
  description = "DNS name for the application"
  value       = var.domain_name
}

output "ssh_command" {
  description = "Command to SSH into the instance"
  value       = "ssh -i ${var.private_key_path} ec2-user@${aws_eip.main.public_ip}"
}

output "web_url" {
  description = "Web URL for the application"
  value       = "http://${aws_eip.main.public_ip}:3000"
}

output "models_volume_id" {
  description = "ID of persistent models EBS volume"
  value       = aws_ebs_volume.models.id
}

output "models_volume_size" {
  description = "Size of persistent models EBS volume (GB)"
  value       = aws_ebs_volume.models.size
}

output "instance_id" {
  description = "Instance ID"
  value       = aws_instance.gpu_instance.id
}