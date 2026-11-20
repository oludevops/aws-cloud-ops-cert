# -----------------------------------------------------------------------------
# Creates one t3.micro EC2 instance (Amazon Linux 2023) in its OWN small VPC
# (VPC + public subnet + internet gateway + route table), with an SSH key pair
# and a security group that allows SSH only from your IP.
#
# A dedicated VPC is used instead of the account's default VPC, because the
# default VPC in this region has no subnets and no free space to add one.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# ---------------------------- Variables --------------------------------------

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-2" # US East (Ohio)
}

variable "instance_name" {
  description = "Name tag for the instance"
  type        = string
  default     = "my_first_instance"
}

variable "private_key_path" {
  description = "Where to save the generated SSH private key on this machine"
  type        = string
  default     = "~/.ssh/my_first_instance.pem"
}

variable "vpc_cidr" {
  description = "IP range for the new VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "IP range for the public subnet (must sit inside vpc_cidr)"
  type        = string
  default     = "10.20.1.0/24"
}

# ---------------------------- Provider ---------------------------------------

provider "aws" {
  region = var.region
}

# ---------------------------- Lookups ----------------------------------------

# Latest Amazon Linux 2023 AMI for x86_64 (t3 instances are x86_64)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Your current public IP, so SSH is not open to the whole internet
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# ---------------------------- Networking -------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.instance_name}-vpc"
  }
}

# Gives the VPC a path to and from the internet
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.instance_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.instance_name}-public-${var.region}a"
  }
}

# Sends all internet-bound traffic (0.0.0.0/0) through the internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.instance_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------- Resources --------------------------------------

# Generates a brand-new SSH key pair for this instance.
# NOTE: the private key is also stored in terraform.tfstate - keep that file private.
resource "tls_private_key" "this" {
  algorithm = "ED25519"
}

# Uploads the public half to AWS as an EC2 key pair
resource "aws_key_pair" "this" {
  key_name   = "${var.instance_name}-key"
  public_key = tls_private_key.this.public_key_openssh

  tags = {
    Name = "${var.instance_name}-key"
  }
}

# Saves the private half locally, readable only by you (chmod 400)
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.this.private_key_openssh
  filename        = pathexpand(var.private_key_path)
  file_permission = "0400"
}

resource "aws_security_group" "ssh" {
  name        = "${var.instance_name}-ssh"
  description = "Allow SSH from my IP only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-ssh"
  }
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.ssh.id]
  associate_public_ip_address = true

  # Hibernation: saves RAM to the (encrypted) root volume on stop.
  # Can only be set at launch - changing it replaces the instance.
  hibernation = true

  # IMDSv2 only (security best practice)
  metadata_options {
    http_tokens = "required"
  }

  # Root volume MUST be encrypted EBS and large enough to hold the RAM
  # (t3.micro has 1 GiB RAM; 8 GiB is ample room for OS + RAM image)
  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name      = var.instance_name
    ManagedBy = "terraform"
  }

  # Make sure the internet route exists before the instance boots
  depends_on = [aws_route_table_association.public]
}

# ---------------------------- Outputs ----------------------------------------

output "vpc_id" {
  value = aws_vpc.this.id
}

output "instance_id" {
  value = aws_instance.this.id
}

output "public_ip" {
  value = aws_instance.this.public_ip
}

output "key_pair_name" {
  value = aws_key_pair.this.key_name
}

output "private_key_file" {
  value = local_sensitive_file.private_key.filename
}

output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_instance.this.public_ip}"
}

