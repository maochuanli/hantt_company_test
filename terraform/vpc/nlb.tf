resource "aws_lb" "main" {
  name               = "${var.vpc_name}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  security_groups    = [aws_security_group.nlb.id]

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name        = "${var.vpc_name}-nlb"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_lb_target_group" "https" {
  name        = "${var.vpc_name}-tg-443"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # TCP health check — VMs serve HTTPS with self-signed certs so TCP is simpler
  health_check {
    protocol            = "TCP"
    port                = "443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name        = "${var.vpc_name}-tg-443"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}
