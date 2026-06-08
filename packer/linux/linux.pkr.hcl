packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1"
    }
  }
}

variable "region" {
  default = "ap-southeast-6"
}

variable "instance_type" {
  default = "t3.small"
}

source "amazon-ebs" "linux" {
  ami_name      = "hantt-nginx-linux-${formatdate("YYYYMMDD-HHmmss", timestamp())}"
  instance_type = var.instance_type
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username                = "ec2-user"
  associate_public_ip_address = true

  tags = {
    Name      = "hantt-nginx-linux"
    OS        = "AmazonLinux2023"
    ManagedBy = "packer"
  }
}

build {
  name    = "hantt-nginx-linux"
  sources = ["source.amazon-ebs.linux"]

  provisioner "ansible" {
    playbook_file   = "${path.root}/ansible/playbook.yml"
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${path.root}/ansible/ansible.cfg",
    ]
    extra_arguments = [
      "-e", "ansible_ssh_transfer_method=piped",
    ]
  }
}
