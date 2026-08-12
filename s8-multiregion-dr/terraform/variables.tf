variable "primary_region" {
  description = "Region that serves traffic while healthy."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Region Route 53 fails over to."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.secondary_region != "us-east-1"
    error_message = "The secondary must be a different region, or there is no DR."
  }
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "lab-s8"
}

variable "table_name" {
  description = "DynamoDB global table. One logical table, a replica per region."
  type        = string
  default     = "HighAvailabilityTable"
}

variable "hosted_zone_id" {
  description = <<-EOT
    Route 53 zone that owns the failover records. Not defaulted: this is
    account-specific, and a wrong value writes records into someone else's zone.
  EOT
  type        = string
}

variable "domain_name" {
  description = <<-EOT
    FQDN clients call. Stays the same through a failover — that is the entire
    point of the design.
  EOT
  type        = string
  default     = "api.lab.andruxa.dev"
}

variable "record_ttl" {
  description = <<-EOT
    TTL on the failover records, in seconds.

    This is the floor on failover time and the most important number here. The
    measured failover in the shell version was 60-80s, and this is why: a
    resolver that cached the primary answer keeps using it until the TTL
    expires, no matter how fast the health check notices. Lower means faster
    failover and more query cost.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.record_ttl >= 10 && var.record_ttl <= 300
    error_message = "Keep the TTL between 10 and 300 for a failover record."
  }
}

variable "health_check_failure_threshold" {
  description = "Consecutive failed checks before Route 53 declares the primary unhealthy."
  type        = number
  default     = 3
}

variable "health_check_interval" {
  description = "Seconds between health checks. 10 or 30; 10 costs more."
  type        = number
  default     = 30

  validation {
    condition     = contains([10, 30], var.health_check_interval)
    error_message = "Route 53 supports 10 or 30 second intervals only."
  }
}
