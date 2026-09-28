# Cost Notes and Teardown

This project is **not** free-tier only. Rough ap-south-1 figures for a stack left
running 24/7 — check current pricing, these are estimates to set expectations.

| Resource | Approx. monthly | Notes |
|---|---|---|
| NAT Gateway | ~$32 + data | The single biggest surprise cost. Required for private-subnet tasks to reach ECR/Secrets Manager. |
| ALB | ~$16 + LCU | Always on |
| ECS Fargate (4 tasks) | ~$25–35 | 2 backend (0.5 vCPU/1GB) + 2 frontend (0.25/0.5) |
| Jenkins EC2 t3.large | ~$60 | Stop it when not in use |
| Redshift Serverless | ~$0.36/RPU-hour | 8 RPU baseline; only bills while queries run, but verify |
| Kinesis (1 shard) | ~$11 | Plus PUT payload units |
| Firehose | ~$0.029/GB | Small at demo volumes |
| Glue | ~$0.44/DPU-hour | 2 × G.1X, billed per job run (1 min minimum) |
| S3 + ECR + CloudWatch | a few dollars | Lifecycle policies included to limit growth |

## Keeping it cheap while learning

- **Stop the Jenkins instance** when you're not building:
  `aws ec2 stop-instances --instance-ids <id>` (you keep the EBS volume, ~$2.40/mo)
- **Destroy the NAT Gateway** between sessions if you can tolerate rebuilding —
  it's the main idle cost.
- Run Glue jobs on demand rather than scheduling them.
- Set a **billing alarm** before you start:
  ```bash
  aws budgets create-budget --account-id <id> --budget \
    '{"BudgetName":"devops-project","BudgetLimit":{"Amount":"50","Unit":"USD"},
      "TimeUnit":"MONTHLY","BudgetType":"COST"}'
  ```

## Teardown

```bash
cd terraform
terraform destroy
```

Terraform will not remove these — check manually in the console:

- The **Terraform state bucket** (created by `bootstrap_backend.sh`) and its
  DynamoDB lock table
- **S3 objects** in versioned buckets — `terraform destroy` fails on non-empty
  buckets. Empty them first:
  ```bash
  aws s3 rm s3://<bucket> --recursive
  ```
  For the versioned curated bucket you also need to delete old versions
  (console: bucket → Empty).
- **CloudWatch log groups** (`/ecs/*`, `/aws/kinesisfirehose/*`) — retention is
  set to 14 days so they age out, but they linger until then
- **Elastic IPs** left unattached (billed when not associated)
- **ECR images** — the lifecycle policy keeps 10; delete the repo to clear all

Verify nothing is left:
```bash
aws ec2 describe-nat-gateways --filter Name=state,Values=available
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
aws ecs list-clusters
aws redshift-serverless list-workgroups
```
