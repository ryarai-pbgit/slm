output "ec2_instance_id" {
  description = "Instance ID of the standalone EC2 inference host"
  value       = var.enable_ec2 ? aws_instance.ec2[0].id : null
}

output "ec2_public_ip" {
  description = "Public IP address of the standalone EC2 inference host"
  value       = var.enable_ec2 ? aws_instance.ec2[0].public_ip : null
}

output "ec2_key_pair_name" {
  description = "Key pair name associated with the standalone EC2 host"
  value = var.enable_ec2 ? (
    var.ec2_key_name != "" ? var.ec2_key_name :
    (var.ec2_public_key != "" ? try(aws_key_pair.ec2[0].key_name, null) : null)
  ) : null
}

