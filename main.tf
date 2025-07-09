resource "aws_lb_target_group" "main" {
  name     = "${var.project}-${var.environment}-${var.component}" ## roboshop-dev-catalogue/user/cart/shipping/payment
  port     = local.target_port
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 60
    matcher             = "200-299"
    path                = local.health_check_path
    port                = local.target_port
    timeout             = 15
    unhealthy_threshold = 3
  }
}

resource "aws_instance" "main" {
  ami                    = local.ami_id
  instance_type          = "t2.micro"
  vpc_security_group_ids = [local.sg_id]
  subnet_id              = local.private_subnet_id
  iam_instance_profile   = "EC2RoleToFetchSSMParameter"  ## required for Shipping and Payment component

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project}-${var.environment}-${var.component}"
    }
  )
}


resource "terraform_data" "main" {
  triggers_replace = [
    aws_instance.main.id
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    password = "DevOps321"
    host     = aws_instance.main.private_ip
  }

  provisioner "file" {
    source      = "bootstrap.sh"
    destination = "/tmp/${var.component}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/${var.component}.sh",
      "sudo sh /tmp/${var.component}.sh ${var.component} ${var.environment}"
    ]
  }
}


resource "aws_ec2_instance_state" "main" {
  instance_id = aws_instance.main.id
  state = "stopped"
  depends_on = [ terraform_data.main ]
}

resource "aws_ami_from_instance" "main" {
  name = "${var.project}-${var.environment}-${var.component}"
  source_instance_id = aws_instance.main.id
  depends_on = [ aws_ec2_instance_state.main ]

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project}-${var.environment}-${var.component}"
    }
  )
}


resource "terraform_data" "main_delete" {
  triggers_replace = [
    aws_instance.main.id
  ]
## make sure that we have aws configure in our laptop
  provisioner "local-exec" {
    command = "aws ec2 terminate-instances --instance-ids ${aws_instance.main.id}"
}
  depends_on = [ aws_ami_from_instance.main ]
}


## launch template
resource "aws_launch_template" "main" {
  name = "${var.project}-${var.environment}-${var.component}"

  image_id = aws_ami_from_instance.main.id
  instance_initiated_shutdown_behavior = "terminate"
  instance_type = "t2.micro"
  vpc_security_group_ids = [local.sg_id]
  update_default_version = true   ## each time you update, new version will become default

  ## EC2 tags created by ASG
  tag_specifications {
    resource_type = "instance"
  
    tags = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )
  }

  ## Volume tags created by ASG
  tag_specifications {
    resource_type = "volume"
  
    tags = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )
  }

    ## Launch template tags
    tags = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )
}


## Auto Scaling Group
resource "aws_autoscaling_group" "main" {
  name = "${var.project}-${var.environment}-${var.component}"
  desired_capacity = 1
  max_size = 10
  min_size = 1
  target_group_arns = [aws_lb_target_group.main.arn]
  vpc_zone_identifier = local.private_subnet_ids
  health_check_grace_period = 120
  health_check_type = "ELB"


  launch_template {
    id = aws_launch_template.main.id
    version = aws_launch_template.main.latest_version
  }

  dynamic "tag" {
    for_each = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )  
    content {
      key = tag.key
      value = tag.value
      propagate_at_launch = true
    }  
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"]
  }

  timeouts {
    delete = "15m"
  }
}

resource "aws_autoscaling_policy" "main" {
  name = "${var.project}-${var.environment}-${var.component}"
  autoscaling_group_name = aws_autoscaling_group.main.name

  policy_type = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}


resource "aws_lb_listener_rule" "main" {
listener_arn = local.alb_listener_arn
priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    host_header {
      values = [local.rule_header_url]
    }
  }
}
