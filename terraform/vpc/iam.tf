resource "aws_iam_role" "nginx_vm" {
  name = "${var.vpc_name}-nginx-vm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.vpc_name}-nginx-vm-role"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "nginx_vm_ssm" {
  role       = aws_iam_role.nginx_vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "nginx_vm_s3_read" {
  role       = aws_iam_role.nginx_vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "nginx_vm" {
  name = "${var.vpc_name}-nginx-vm-profile"
  role = aws_iam_role.nginx_vm.name
}
