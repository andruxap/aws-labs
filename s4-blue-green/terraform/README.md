# S4 in Terraform

The same stack as [`../scripts/deploy.sh`](../scripts/deploy.sh), expressed as a resource graph. Written and validated; **not applied** — `terraform plan` reads the AWS API but creates nothing and costs nothing.

```
terraform init && terraform validate && terraform plan
Plan: 14 to add, 0 to change, 0 to destroy.
```

## Why rebuild it

The console pass teaches which services exist. The Terraform pass teaches how they depend on each other — and here it turns a procedure into a value.

In the shell version, the cutover is a sequence of API calls:

```bash
aws elbv2 modify-listener --listener-arn "$LISTENER" \
  --default-actions "Type=forward,TargetGroupArn=$TG"
```

In Terraform it's one variable:

```bash
terraform apply -var active_environment=green
```

`var.active_environment` is referenced by exactly **one** resource — `aws_lb_listener.http`:

```hcl
resource "aws_lb_listener" "http" {
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.env[var.active_environment].arn
  }
}
```

Everything else — both launch templates, both target groups, both ASGs, the ALB, the IAM role — is identical either way. So the cutover is a one-resource in-place update, and the rollback is the same command with the other value. The blue/green property stops being a thing you remember to do correctly and becomes a thing the configuration guarantees.

**Honest limit:** with empty state, `plan -var active_environment=blue` and `-var active_environment=green` both report `14 to add` — an empty-state plan can't show a one-resource diff. The proof above is structural (only one resource reads the variable), not a captured plan. Demonstrating the 1-change diff for real needs an apply first, which is why this is written but not run.

## What the config demonstrates

**`for_each` over a map of environments** rather than duplicated blue/green blocks. Adding a third environment is a map entry, not a copy-paste of five resources.

```hcl
variable "environments" {
  type = map(object({ app_version = string }))
  default = {
    blue  = { app_version = "v1.0" }
    green = { app_version = "v2.0" }
  }
}
```

**`instance_refresh` as configuration.** In the shell version the rolling deploy was an imperative `start-instance-refresh` call. Here it's a property of the ASG: change the user data or the AMI, and the next apply rolls the fleet rather than replacing the group.

```hcl
instance_refresh {
  strategy = "Rolling"
  preferences {
    min_healthy_percentage = 50
    instance_warmup        = 60
  }
  triggers = ["desired_capacity"]
}
```

`launch_template` is deliberately **not** in `triggers` — a template change always triggers a refresh, and listing it explicitly is a validation warning. That warning is why it isn't there.

**`create_before_destroy` on the launch templates and ASGs.** A launch template referenced by a running ASG cannot be destroyed, so the replacement has to exist first. This is the ordering that a hand-written script gets wrong.

**`deregistration_delay = 30`** on the target groups. This is the setting behind the measured result in the parent README: planned changes lost **zero** requests while an abrupt termination lost **~4%**. Draining is what makes the difference, and it's one line here.

**AMI from SSM, not a hardcoded id**, so the config doesn't rot — with the trade-off stated in a comment: a new AL2023 release becomes a real diff on the next plan.

## Files

| | |
|---|---|
| `versions.tf` | Provider pin + `default_tags` so every resource is tagged `Lab=s4` without repetition |
| `variables.tf` | Typed inputs with `validation` blocks — capacity bounded, `active_environment` restricted to blue/green |
| `main.tf` | The graph: lookups → IAM → SG → launch templates → target groups → ALB → listener → ASGs |
| `outputs.tf` | ALB DNS, both ASG names, and a generated `cutover_command` |
| `../user-data/app.sh.tftpl` | `templatefile()` version of the boot script |

## The templating gotcha

Porting a shell script to a `.tftpl` breaks on `$`. Terraform reads `${VAR}` as its own interpolation, so every **shell** variable has to be escaped as `$${VAR}`:

```bash
IID=$(meta instance-id)          # fine — no braces
echo "${environment} $${IID}"    # environment = Terraform, IID = shell
```

Miss one and the plan fails with an unhelpful "Invalid template interpolation value", pointing at the template rather than the line.

## Running it

```bash
terraform init
terraform validate
terraform plan                                   # free, creates nothing

# only if you intend to spend ~$0.075/hr:
terraform apply
curl -s "$(terraform output -raw alb_dns_name)/whoami.txt"    # BLUE v1.0
terraform apply -var active_environment=green                 # the cutover
curl -s "$(terraform output -raw alb_dns_name)/whoami.txt"    # GREEN v2.0
terraform destroy
```

`terraform destroy` replaces the 100-line [`../scripts/teardown.sh`](../scripts/teardown.sh) and its hand-maintained dependency ordering — arguably the strongest practical argument for IaC in this whole repo.
