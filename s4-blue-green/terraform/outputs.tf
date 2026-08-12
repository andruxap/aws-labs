output "alb_dns_name" {
  description = "Public entry point. Same URL regardless of which environment is live."
  value       = aws_lb.main.dns_name
}

output "active_environment" {
  description = "Which environment the listener currently forwards to."
  value       = var.active_environment
}

output "target_group_arns" {
  description = "Both target groups, keyed by environment."
  value       = { for k, tg in aws_lb_target_group.env : k => tg.arn }
}

output "autoscaling_group_names" {
  description = "Both ASGs. Useful for `aws autoscaling describe-instance-refreshes`."
  value       = { for k, asg in aws_autoscaling_group.env : k => asg.name }
}

output "cutover_command" {
  description = "How to move traffic to the other environment."
  value = format(
    "terraform apply -var active_environment=%s",
    var.active_environment == "blue" ? "green" : "blue"
  )
}

output "verify_command" {
  description = "Which environment is answering right now."
  value       = "curl -s http://${aws_lb.main.dns_name}${var.health_check_path}"
}
