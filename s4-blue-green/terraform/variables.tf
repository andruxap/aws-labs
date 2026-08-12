variable "region" {
  description = "Region for the whole stack. Everything is regional; do not mix."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "lab-s4"
}

variable "instance_type" {
  description = "Instance size for both environments."
  type        = string
  default     = "t3.micro"
}

variable "capacity" {
  description = <<-EOT
    Desired instances PER ENVIRONMENT. Blue/green runs both at once, so the
    real instance count is double this — that doubled capacity is the cost the
    strategy trades for an instant switch and an instant way back.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.capacity >= 1 && var.capacity <= 4
    error_message = "capacity must be between 1 and 4 — this is a lab, not production."
  }
}

variable "environments" {
  description = <<-EOT
    The two environments and the app version each one runs. Keyed by colour so
    every resource can be built with for_each instead of copy-pasted blocks.
  EOT
  type = map(object({
    app_version = string
  }))
  default = {
    blue  = { app_version = "v1.0" }
    green = { app_version = "v2.0" }
  }

  validation {
    condition     = length(var.environments) == 2
    error_message = "Blue/green needs exactly two environments."
  }
}

variable "active_environment" {
  description = <<-EOT
    Which environment the ALB listener sends traffic to. THIS is the cutover:

        terraform apply -var active_environment=green

    One variable, one changed resource (the listener's default action). Both
    environments keep running, so switching back is the same command with the
    other value — which is what makes rollback fast.
  EOT
  type        = string
  default     = "blue"

  validation {
    condition     = contains(["blue", "green"], var.active_environment)
    error_message = "active_environment must be blue or green."
  }
}

variable "health_check_path" {
  description = "Plain-text endpoint so tests can assert on content, not HTML."
  type        = string
  default     = "/whoami.txt"
}
