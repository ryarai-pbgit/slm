locals {
  ec2_default_user_data = <<-EOT
#!/bin/bash
set -euxo pipefail
dnf -y update
dnf -y install docker
systemctl enable --now docker
usermod -a -G docker ec2-user || true
EOT
}

resource "aws_key_pair" "ec2" {
  count = var.enable_ec2 && var.ec2_public_key != "" && var.ec2_key_name == "" ? 1 : 0

  key_name   = "${var.project_name}-ec2-key"
  public_key = var.ec2_public_key

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

data "aws_ami" "dlami" {
  count       = var.enable_ec2 && var.ec2_ami_id == "" ? 1 : 0
  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.8 (Amazon Linux 2023)*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_iam_role" "ec2" {
  count = var.enable_ec2 ? 1 : 0

  name = "${var.project_name}-ec2-role"

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
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  count      = var.enable_ec2 ? 1 : 0
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_ecr" {
  count      = var.enable_ec2 ? 1 : 0
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.enable_ec2 ? 1 : 0

  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2[0].name
}

resource "aws_security_group" "ec2" {
  count       = var.enable_ec2 ? 1 : 0
  name        = "${var.project_name}-ec2-sg"
  description = "Access rules for the standalone inference EC2 host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ec2_allowed_cidrs
  }

  ingress {
    description = "vLLM (TCP 8000)"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = var.ec2_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_instance" "ec2" {
  count = var.enable_ec2 ? 1 : 0

  ami                         = var.ec2_ami_id != "" ? var.ec2_ami_id : data.aws_ami.dlami[0].id
  instance_type               = var.ec2_instance_type
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  key_name                    = var.ec2_key_name != "" ? var.ec2_key_name : (var.ec2_public_key != "" ? try(aws_key_pair.ec2[0].key_name, null) : null)
  iam_instance_profile        = aws_iam_instance_profile.ec2[0].name
  vpc_security_group_ids      = [aws_security_group.ec2[0].id]
  monitoring                  = true

  root_block_device {
    volume_size           = var.ec2_volume_size
    volume_type           = "gp3"
    iops                  = var.ec2_volume_iops
    throughput            = var.ec2_volume_throughput
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_protocol_ipv6          = "disabled"
  }

  user_data = var.ec2_user_data != "" ? var.ec2_user_data : local.ec2_default_user_data

  tags = {
    Name        = "${var.project_name}-ec2"
    Environment = var.environment
    Project     = var.project_name
  }
}

