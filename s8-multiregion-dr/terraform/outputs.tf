output "failover_endpoint" {
  description = "The one URL clients use. Unchanged across a failover."
  value       = "https://${var.domain_name}"
}

output "regional_endpoints" {
  description = "Each region's API directly — for proving which one answered."
  value = {
    primary   = aws_apigatewayv2_api.primary.api_endpoint
    secondary = aws_apigatewayv2_api.secondary.api_endpoint
  }
}

output "health_check_ids" {
  description = "Route 53 health checks. Disabling the primary is how failover is tested."
  value = {
    primary   = aws_route53_health_check.primary.id
    secondary = aws_route53_health_check.secondary.id
  }
}

output "global_table_replicas" {
  description = "Regions holding a replica of the table."
  value       = concat([var.primary_region], [for r in aws_dynamodb_table.orders.replica : r.region_name])
}

output "worst_case_failover_seconds" {
  description = <<-EOT
    WORST CASE, not a typical figure: every health check having to fail
    (threshold x interval) plus a resolver holding a cached answer for the full
    TTL. With the defaults that is 3 x 30 + 60 = 150s.

    The shell version measured 60-80s, comfortably better — because a check
    usually fails partway through an interval and resolvers rarely hold an
    answer for the entire TTL. Quote this number as the ceiling you design for,
    and the measured one as what actually happened.
  EOT
  value       = (var.health_check_failure_threshold * var.health_check_interval) + var.record_ttl
}

output "monthly_health_check_cost_usd" {
  description = "The only thing here that bills whether or not anyone calls the API."
  value       = 2 * 0.50
}
