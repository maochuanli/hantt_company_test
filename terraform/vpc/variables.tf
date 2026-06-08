variable "web_identity_token_file" {
  description = "Path to the Azure OIDC token file for AWS authentication"
  type        = string
}

variable "vpc_name" {
  description = "Name tag for the VPC"
  type        = string
  default     = "hantt-main-vpc"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr_a" {
  description = "CIDR block for the public subnet in AZ-a"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_cidr_b" {
  description = "CIDR block for the public subnet in AZ-b"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnet_cidr_a" {
  description = "CIDR block for the private subnet in AZ-a"
  type        = string
  default     = "10.0.3.0/24"
}

variable "private_subnet_cidr_b" {
  description = "CIDR block for the private subnet in AZ-b"
  type        = string
  default     = "10.0.4.0/24"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "nginx_ami_id" {
  description = "AMI ID for Windows Nginx VMs"
  type        = string
}

variable "linux_ami_id" {
  description = "AMI ID for Linux Nginx VMs"
  type        = string
}

variable "vm_instance_type" {
  description = "EC2 instance type for Nginx VMs"
  type        = string
  default     = "t3.small"
}

variable "asg_min" {
  description = "Minimum number of instances in the ASG"
  type        = number
  default     = 1
}

variable "asg_max" {
  description = "Maximum number of instances in the ASG"
  type        = number
  default     = 2
}

variable "asg_desired" {
  description = "Desired number of instances in the ASG"
  type        = number
  default     = 1
}
