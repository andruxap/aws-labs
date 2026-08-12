# S8 in Terraform

The same stack as [`../scripts/deploy.sh`](../scripts/deploy.sh) as a resource graph. Written, formatted, validated, planned — **not applied**. `terraform plan` reads the AWS API and creates nothing.

```
terraform init && terraform validate && terraform plan
Plan: 20 to add, 0 to change, 0 to destroy.
```

## The pattern this exists to demonstrate

A `provider` block is **per-region**. There is no `region` argument on a resource. Multi-region therefore means multiple configured providers, distinguished by `alias`, with every regional resource naming the one it belongs to:

```hcl
provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}

resource "aws_lambda_function" "secondary" {
  provider = aws.secondary   # <- without this it silently lands in the default region
  ...
}
```

Getting an alias wrong builds the resource in the wrong region and nothing complains. That's the most common multi-region mistake, and the console version hides it behind two browser tabs — you only notice when a health check can't find its target.

There's a **third** alias, `aws.global`, pinned to `us-east-1`. Route 53 is a global service but its API is served from us-east-1, and health checks can only be created there. Giving that its own alias makes the constraint deliberate rather than an accident of which region happened to be default.

## What the plan shows

20 resources — and the shape of that number is the lesson:

| Count | Resources | Why |
|---|---|---|
| **1** | `aws_dynamodb_table.orders` | A global table is **one** logical table with a `replica` block. DynamoDB owns the replication. This is the only stateful thing and the only thing not duplicated |
| **3** | IAM role, inline policy, attachment | IAM is global — one role, used by Lambdas in both regions |
| **16** | Lambda, API, integration, route, stage, permission, health check, record | Duplicated per region: 8 pairs |

That 1 / 3 / 16 split *is* the architecture. One replicated data plane, one global identity plane, and a compute plane you build twice.

### Terraform can't `for_each` over providers

A provider alias is not a value, so this doesn't work:

```hcl
for_each = { primary = aws.primary, secondary = aws.secondary }   # invalid
```

Which is why the 16 regional resources are written out explicitly rather than looped. In a production stack you'd put the regional half in a **module** and call it twice with different `providers = {}` — that's the real answer to the duplication. I kept it flat here so the pattern is visible instead of hidden behind a module boundary, but the module version is what you'd ship.

## Numbers the config computes

```
worst_case_failover_seconds   = 150
monthly_health_check_cost_usd = 1
global_table_replicas         = ["us-east-1", "us-west-2"]
```

**150 s is the worst case**: every health check having to fail (`threshold × interval` = 3 × 30) plus a resolver holding a cached answer for the full TTL (60). The shell version **measured 60–80 s**, comfortably better, because a check usually fails partway through an interval and resolvers rarely hold an answer for the entire TTL. Design for the ceiling; quote the measurement as what happened.

`var.record_ttl` is the variable that matters most here. It's the floor on how fast anyone can fail over, no matter how quickly Route 53 notices — a resolver that cached the primary keeps using it until the TTL expires. Lower means faster failover and more query cost.

**$1/month in health checks is the only thing that bills whether or not anyone calls the API.** Everything else — DynamoDB on-demand, Lambda, HTTP API — is per-request and effectively free at lab volume. That's why S8 originally cost $0.06.

## The health-check trap

Each health check targets its **own region's API endpoint directly**, never the failover DNS name:

```hcl
fqdn = replace(aws_apigatewayv2_api.primary.api_endpoint, "https://", "")
```

Pointing a health check at the record it controls is circular: the primary fails, DNS moves to secondary, the primary's check now resolves to the *secondary* and reports healthy, and traffic flaps back to a region that's still broken. A DR setup that can't fail back is worse than one that can't fail over, because it looks fine.

## Files

| | |
|---|---|
| `versions.tf` | Three provider aliases with `default_tags` marking each resource's role |
| `variables.tf` | Typed inputs; `hosted_zone_id` is deliberately **not** defaulted — a wrong value writes records into someone else's zone |
| `main.tf` | Global table → IAM → 8 regional pairs → health checks → failover records |
| `outputs.tf` | Endpoints, health check ids, and the computed worst-case failover |
| `terraform.tfvars.example` | Copy to `terraform.tfvars`; that file is gitignored |

## Running it

```bash
terraform init
terraform validate
terraform plan -var "hosted_zone_id=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='example.com.'].Id" --output text | sed 's|/hostedzone/||')"

# only if you intend to spend ~$0.06:
terraform apply
curl -s "$(terraform output -raw failover_endpoint)/health"
terraform destroy      # replaces the 9-step teardown script
```

`terraform destroy` is the practical argument here. The shell teardown has to delete in a hand-maintained order across two regions, and **health checks are the thing that survives every other teardown** at $0.50/month each. Terraform tracks them in state and removes them without anyone remembering they exist.
