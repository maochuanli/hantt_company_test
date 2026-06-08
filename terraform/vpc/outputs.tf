output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_a_id" {
  description = "ID of the public subnet in AZ-a"
  value       = aws_subnet.public_a.id
}

output "public_subnet_b_id" {
  description = "ID of the public subnet in AZ-b"
  value       = aws_subnet.public_b.id
}

output "private_subnet_a_id" {
  description = "ID of the private subnet in AZ-a"
  value       = aws_subnet.private_a.id
}

output "private_subnet_b_id" {
  description = "ID of the private subnet in AZ-b"
  value       = aws_subnet.private_b.id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway"
  value       = aws_internet_gateway.main.id
}

output "nlb_dns_name" {
  description = "DNS name of the NLB — access your service at https://<this>"
  value       = aws_lb.main.dns_name
}

output "nlb_arn" {
  description = "ARN of the NLB"
  value       = aws_lb.main.arn
}

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.nginx.name
}
