terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "vm_count" {
  description = "Number of VMs to deploy"
  type        = number
  default     = 2
}

resource "aws_instance" "vm" {
  count         = var.vm_count
  ami           = "ami-0c02fb55956c7d316"  # Ubuntu AMI
  instance_type = "t2.micro"

  tags = {
    Name = "VM-${count.index}"
  }
}

output "vm_public_ips" {
  value = aws_instance.vm[*].public_ip
}
