terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

# THE PATTERN THIS PROJECT EXISTS TO DEMONSTRATE.
#
# A provider block is per-region. Multi-region therefore means multiple
# configured providers, distinguished by alias, and every regional resource
# declaring which one it belongs to:
#
#     provider = aws.primary     or     provider = aws.secondary
#
# There is no "region" argument on a resource. Get the alias wrong and you
# silently build in the wrong region — the single most common multi-region
# mistake, and the one the console version hides behind two browser tabs.

provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = {
      Lab       = "s8"
      ManagedBy = "terraform"
      Role      = "primary"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = {
      Lab       = "s8"
      ManagedBy = "terraform"
      Role      = "secondary"
    }
  }
}

# Route 53 is global, but its API is served from us-east-1. Health checks in
# particular can only be created there. Keeping a third alias makes that
# constraint explicit rather than an accident of which region came first.
provider "aws" {
  alias  = "global"
  region = "us-east-1"

  default_tags {
    tags = {
      Lab       = "s8"
      ManagedBy = "terraform"
      Role      = "global"
    }
  }
}
