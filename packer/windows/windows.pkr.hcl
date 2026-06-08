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
  default = "m7i-flex.large"
}

source "amazon-ebs" "windows" {
  ami_name               = "hantt-nginx-windows-${formatdate("YYYYMMDD-HHmmss", timestamp())}"
  instance_type          = var.instance_type
  region                 = var.region
  skip_region_validation = true

  source_ami_filter {
    filters = {
      name                = "Windows_Server-2022-English-Full-Base-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  communicator                = "winrm"
  winrm_username              = "Administrator"
  winrm_use_ssl               = true
  winrm_insecure              = true
  winrm_timeout               = "20m"
  associate_public_ip_address = true
  user_data_file              = "${path.root}/winrm-setup.ps1"

  tags = {
    Name      = "hantt-nginx-windows"
    OS        = "WindowsServer2022"
    ManagedBy = "packer"
  }
}

build {
  name    = "hantt-nginx-windows"
  sources = ["source.amazon-ebs.windows"]

  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/playbook.yml"
    user          = "Administrator"
    use_proxy     = false
    extra_arguments = [
      "-e", "ansible_connection=winrm",
      "-e", "ansible_winrm_transport=basic",
      "-e", "ansible_winrm_server_cert_validation=ignore",
      "-e", "ansible_winrm_port=5986",
    ]
  }
}
