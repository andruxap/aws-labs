# S4 — Blue/Green and rolling deployments, as code.
#
# The console version of this lab is scripts/deploy.sh. This is the same stack
# expressed as a resource graph, which is where the interesting part lives:
# the cutover stops being a sequence of API calls and becomes one variable.
#
#     terraform apply -var active_environment=green
#
# Only aws_lb_listener.http changes. Both ASGs keep running.

# ------------------------------------------------------------------ lookups --
# The lab uses the default VPC deliberately: this project is about deployment
# strategy, not networking. S6 builds VPCs from nothing.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023 from SSM rather than a pinned AMI id, so the config
# does not rot. Note the trade-off: a new AMI release changes the launch
# template, which is a real diff on the next plan.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --------------------------------------------------------------------- IAM ---
# SSM Session Manager instead of a key pair: no inbound SSH anywhere, and the
# lab's test scripts can run commands through the AWS API.
#
# Under /workload/ with the BuilderBoundary ceiling: the daily Builder login can
# only create roles that carry both (resume-website plan 020, step 12). The ARN
# is built from the caller's account, never committed.
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "ec2" {
  name                 = "${var.name}-ec2-role"
  path                 = "/workload/"
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/boundary/BuilderBoundary"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2-role"
  path = "/workload/"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------- security group ---
resource "aws_security_group" "web" {
  name        = "${var.name}-sg"
  description = "S4 blue/green - HTTP from anywhere, no SSH"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP from anywhere (ALB and direct)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "Outbound for dnf and the SSM agent"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --------------------------------------------------------- launch templates --
# One template per environment. In the console lab these were versions of a
# single template; separate templates express the same thing more clearly here,
# and each ASG references its own by version = "$Latest".
resource "aws_launch_template" "env" {
  for_each = var.environments

  name_prefix   = "${var.name}-${each.key}-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = base64encode(templatefile("${path.module}/../user-data/app.sh.tftpl", {
    environment = upper(each.key)
    app_version = each.value.app_version
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "${var.name}-${each.key}"
      Env        = upper(each.key)
      AppVersion = each.value.app_version
    }
  }

  # A template a running ASG references cannot be destroyed, so build the
  # replacement before removing the old one.
  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------ target groups --
resource "aws_lb_target_group" "env" {
  for_each = var.environments

  name        = "${var.name}-${each.key}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    path                = var.health_check_path
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  # Give in-flight requests time to finish when a target is deregistered. This
  # is the setting that made planned changes lose zero requests while an abrupt
  # terminate lost ~4% — see the README.
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------- ALB --
resource "aws_lb" "main" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.web.id]
  subnets            = slice(data.aws_subnets.default.ids, 0, 2)

  # Left off deliberately: this stack is destroyed the same day, and enabling
  # it would block `terraform destroy` on a lab.
  enable_deletion_protection = false
}

# THE CUTOVER. Everything else in this file is scaffolding; this one argument
# is what moves production traffic. Changing var.active_environment produces a
# one-resource diff.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.env[var.active_environment].arn
  }
}

# --------------------------------------------------------------------- ASGs --
resource "aws_autoscaling_group" "env" {
  for_each = var.environments

  name                = "${var.name}-${each.key}-asg"
  vpc_zone_identifier = slice(data.aws_subnets.default.ids, 0, 2)
  target_group_arns   = [aws_lb_target_group.env[each.key].arn]

  min_size         = 1
  max_size         = 4
  desired_capacity = var.capacity

  # ELB rather than EC2: the ASG then replaces an instance the load balancer
  # considers unhealthy, not merely one that has powered off.
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.env[each.key].id
    version = "$Latest"
  }

  # The rolling deployment, declaratively. Change the user data or AMI and the
  # next apply rolls the fleet instead of replacing the group. 50% keeps half
  # the capacity serving throughout.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 60
    }
    # launch_template is NOT listed: a template change always triggers a
    # refresh, and naming it explicitly is a validation warning. Only the extra
    # triggers belong here.
    triggers = ["desired_capacity"]
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-${each.key}"
    propagate_at_launch = true
  }

  timeouts {
    delete = "15m"
  }

  lifecycle {
    create_before_destroy = true
  }
}
