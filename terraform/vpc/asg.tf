resource "aws_launch_template" "nginx" {
  name_prefix   = "${var.vpc_name}-nginx-"
  image_id      = var.nginx_ami_id
  instance_type = var.vm_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.nginx_vm.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.private_vm.id]
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(<<-EOF
    <powershell>
    # Fetch IMDSv2 token then pull instance metadata
    $token        = Invoke-RestMethod -Method Put `
                      -Uri "http://169.254.169.254/latest/api/token" `
                      -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"}
    $hdrs         = @{"X-aws-ec2-metadata-token"=$token}
    $instanceId   = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id"                    -Headers $hdrs
    $az           = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/availability-zone"   -Headers $hdrs
    $localIp      = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/local-ipv4"                    -Headers $hdrs
    $instanceType = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-type"                 -Headers $hdrs
    $launched     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC")

    # Locate Chocolatey nginx installation (e.g. C:\tools\nginx-1.x.x)
    $nginxDir = (Get-ChildItem "C:\tools" -Filter "nginx-*" -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending | Select-Object -First 1).FullName
    if (-not $nginxDir) { $nginxDir = "C:\nginx" }

    $html = @"
<!DOCTYPE html>
<html>
<head><title>Hantt Hello World</title>
<style>
  body { font-family: monospace; background: #0d1117; color: #c9d1d9; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 2rem 3rem; max-width: 480px; }
  h1 { color: #58a6ff; margin-top: 0; }
  .label { color: #8b949e; font-size: 0.85em; }
  .value { color: #e6edf3; margin-bottom: 0.8rem; }
</style>
</head>
<body>
<div class="card">
  <h1>Hello World</h1>
  <div class="label">Platform</div><div class="value">Windows Server 2022</div>
  <div class="label">Instance ID</div><div class="value">$instanceId</div>
  <div class="label">Availability Zone</div><div class="value">$az</div>
  <div class="label">Private IP</div><div class="value">$localIp</div>
  <div class="label">Instance Type</div><div class="value">$instanceType</div>
  <div class="label">Launched</div><div class="value">$launched</div>
</div>
</body>
</html>
"@

    Set-Content -Path "$nginxDir\html\index.html" -Value $html -Encoding UTF8
    </powershell>
    EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type = "gp3"
      volume_size = 30
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.vpc_name}-nginx-windows"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nginx" {
  name                = "${var.vpc_name}-nginx-asg"
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns   = [aws_lb_target_group.https.arn]
  health_check_type   = "ELB"

  min_size         = var.asg_min
  max_size         = var.asg_max
  desired_capacity = var.asg_desired

  launch_template {
    id      = aws_launch_template.nginx.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.vpc_name}-nginx"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}

resource "aws_launch_template" "nginx_linux" {
  name_prefix   = "${var.vpc_name}-nginx-linux-"
  image_id      = var.linux_ami_id
  instance_type = var.vm_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.nginx_vm.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.private_vm.id]
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/availability-zone)
    LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/local-ipv4)
    INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-type)
    LAUNCHED=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    cat > /usr/share/nginx/html/index.html <<HTML
    <!DOCTYPE html>
    <html>
    <head><title>Hantt Hello World</title>
    <style>
      body { font-family: monospace; background: #0d1117; color: #c9d1d9; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
      .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 2rem 3rem; max-width: 480px; }
      h1 { color: #58a6ff; margin-top: 0; }
      .label { color: #8b949e; font-size: 0.85em; }
      .value { color: #e6edf3; margin-bottom: 0.8rem; }
    </style>
    </head>
    <body>
    <div class="card">
      <h1>Hello World</h1>
      <div class="label">Platform</div><div class="value">Amazon Linux 2023</div>
      <div class="label">Instance ID</div><div class="value">$INSTANCE_ID</div>
      <div class="label">Availability Zone</div><div class="value">$AZ</div>
      <div class="label">Private IP</div><div class="value">$LOCAL_IP</div>
      <div class="label">Instance Type</div><div class="value">$INSTANCE_TYPE</div>
      <div class="label">Launched</div><div class="value">$LAUNCHED</div>
    </div>
    </body>
    </html>
    HTML
    EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type = "gp3"
      volume_size = 30
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.vpc_name}-nginx-linux"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nginx_linux" {
  name                = "${var.vpc_name}-nginx-linux-asg"
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns   = [aws_lb_target_group.https.arn]
  health_check_type   = "ELB"

  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  launch_template {
    id      = aws_launch_template.nginx_linux.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.vpc_name}-nginx-linux"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.vpc_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.nginx.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
