resource "aws_security_group" "nlb" {
  name        = "${var.vpc_name}-nlb-sg"
  description = "NLB - allow HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.vpc_name}-nlb-sg"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_security_group" "private_vm" {
  name        = "${var.vpc_name}-private-vm-sg"
  description = "Private VMs - HTTPS only from NLB security group, SSH from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from NLB only"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  ingress {
    description = "SSH within VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.vpc_name}-private-vm-sg"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
