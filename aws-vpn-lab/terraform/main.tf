// aws-vpn-lab: one Ubuntu EC2 in its own VPC, terminating an IKEv2 route-based
// VPN (strongSwan) from the home Cisco C841M. See ../README.md.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = { Project = "aws-vpn-lab" }
  }
}

variable "home_cidr" {
  description = "Home public IP (/32). The Cisco's IKE/NAT-T traffic and SSH from this PC come from here."
  type        = string
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/aws-vpn-lab.pub"
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
}

locals {
  vpc_cidr       = "10.20.0.0/16"
  subnet_cidr    = "10.20.1.0/24"
  private_ip     = "10.20.1.10"
  home_networks  = ["10.10.10.0/24", "10.10.11.0/24"] // behind the Cisco
  tunnel_network = "169.254.201.0/30"                 // Cisco .1, EC2 .2
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "aws_availability_zones" "az" {
  state = "available"
}

resource "aws_vpc" "lab" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "aws-vpn-lab" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "aws-vpn-lab" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = local.subnet_cidr
  availability_zone = data.aws_availability_zones.az.names[0]
  tags              = { Name = "aws-vpn-lab-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  // Home networks are reached through the VPN instance, so anything added to
  // this subnet later can talk to the Cisco side too.
  dynamic "route" {
    for_each = local.home_networks
    content {
      cidr_block           = route.value
      network_interface_id = aws_instance.vpn.primary_network_interface_id
    }
  }
  tags = { Name = "aws-vpn-lab-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "vpn" {
  name        = "aws-vpn-lab"
  description = "IKE/NAT-T and SSH from home, anything from the home networks"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = [var.home_cidr]
  }
  ingress {
    description = "IKE NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = [var.home_cidr]
  }
  ingress {
    description = "SSH from the home PC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.home_cidr]
  }
  ingress {
    description = "Home networks behind the Cisco (for other instances in this subnet)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.home_networks
  }
  egress {
    description = "Package updates and replies"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "lab" {
  key_name   = "aws-vpn-lab"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "vpn" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.private_ip
  vpc_security_group_ids = [aws_security_group.vpn.id]
  key_name               = aws_key_pair.lab.key_name
  source_dest_check      = false // it routes for the home networks
  user_data              = file("${path.module}/user-data.sh")

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }
  lifecycle {
    ignore_changes = [ami, user_data] // a newer AMI must not replace a running lab
  }
  tags = { Name = "aws-vpn-lab" }
}

// Fixed public IP, so the Cisco's peer address survives stop/start.
resource "aws_eip" "vpn" {
  domain   = "vpc"
  instance = aws_instance.vpn.id
  tags     = { Name = "aws-vpn-lab" }
}

// Auto-stop every night at 23:00 JST, so a forgotten "vm.ps1 start" does not run
// all month. Runs in AWS (EventBridge Scheduler), so it works with the home PC off.
// Starting again is manual (vm.ps1 start).
variable "auto_stop_cron" {
  description = "EventBridge Scheduler cron for the nightly stop, in Asia/Tokyo time"
  type        = string
  default     = "cron(0 23 * * ? *)"
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "auto_stop" {
  name               = "aws-vpn-lab-auto-stop"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "auto_stop" {
  name = "stop-vpn-instance"
  role = aws_iam_role.auto_stop.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = aws_instance.vpn.arn
    }]
  })
}

resource "aws_scheduler_schedule" "auto_stop" {
  name                         = "aws-vpn-lab-auto-stop"
  schedule_expression          = var.auto_stop_cron
  schedule_expression_timezone = "Asia/Tokyo"
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.auto_stop.arn
    input    = jsonencode({ InstanceIds = [aws_instance.vpn.id] })
  }
}

output "instance_id" {
  value = aws_instance.vpn.id
}

output "public_ip" {
  value = aws_eip.vpn.public_ip
}

output "private_ip" {
  value = local.private_ip
}
