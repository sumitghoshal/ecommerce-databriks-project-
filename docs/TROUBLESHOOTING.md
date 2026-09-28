# Troubleshooting

Ordered roughly by how often they bite people on a first build.

## Terraform

**`Error: creating S3 Bucket: BucketAlreadyExists`**
S3 bucket names are globally unique. Change `bucket_suffix` in `terraform.tfvars`.

**`InsufficientSubnetsInVPC` on the Redshift workgroup**
Redshift Serverless requires subnets in **at least 3 AZs**. `vpc.tf` creates 3
private subnets for exactly this reason — don't reduce the count to 2.

**`Error acquiring the state lock`**
A previous run died mid-apply. Confirm nothing else is running, then:
`terraform force-unlock <LOCK_ID>`

**`no such file or directory: ../devops-project-key.pub`**
`jenkins.tf` reads your SSH public key from the repo root:
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/devops-project-key
cp ~/.ssh/devops-project-key.pub ./devops-project-key.pub
```

**`terraform destroy` fails: "BucketNotEmpty"**
Empty the buckets first — `aws s3 rm s3://<bucket> --recursive`. For the curated
bucket (versioned), delete old versions via the console's "Empty" action.

## ECS / application

**Service shows 0 running tasks, "unable to pull image"**
Expected before your first image push. ECS task definitions reference
`:latest`, which doesn't exist until `scripts/deploy.sh` or the Jenkins pipeline
runs once. Run `./scripts/deploy.sh` then re-check.

**Tasks start then immediately stop — `ResourceInitializationError ... secretsmanager`**
The task **execution** role can't read the secret. `iam.tf` attaches
`ecs_read_secrets` for this; confirm the policy exists and that
`aws_secretsmanager_secret.mongo_uri` matches what the task definition references.

**Backend target group shows "unhealthy"**
Check in order:
1. Security group — `tasks_from_alb_backend` must allow port 5000 from the ALB SG.
2. Health check path is `/health` (the ALB hits the task IP directly, so it does
   **not** go through the `/api/*` listener rule).
3. Container logs: `aws logs tail /ecs/ecommerce-devops-backend --follow`

**Frontend loads but the orders list shows an error**
The browser calls `/api/orders`. Verify the ALB listener rule for `/api/*`
exists and points at the backend target group:
```bash
aws elbv2 describe-rules --listener-arn <arn>
```
Note the frontend health badge calls `/api/health`, not `/health` — only `/api/*`
is routed to the backend.

**Tasks can't reach ECR or Secrets Manager from private subnets**
The NAT Gateway must exist and the private route table must route `0.0.0.0/0`
through it. Check `aws ec2 describe-nat-gateways`.

## Jenkins

**`sonar-scanner: command not found` (stage 3)**
You configured the SonarQube *server* but not the *scanner tool*. Both are
required — see `docs/JENKINS_SETUP.md` step 4.

**SonarQube container keeps restarting**
Elasticsearch bootstrap check. On the EC2 box:
```bash
docker logs sonarqube | grep max_map_count
sudo sysctl -w vm.max_map_count=262144
docker restart sonarqube
```
`install_jenkins.sh` sets this automatically; if you installed by hand, you must.

**Builds get killed with no error / OOM**
t3.medium is too small once SonarQube is co-located. Use **t3.large**, or move
SonarQube to a separate instance.

**`docker: permission denied` in the pipeline**
The jenkins user isn't in the docker group yet, or Jenkins wasn't restarted:
```bash
sudo usermod -aG docker jenkins && sudo systemctl restart jenkins
```

**Deploy stage: `AccessDeniedException` on ecs:UpdateService**
The `aws-creds` IAM user lacks ECS permissions. Either attach the
`jenkins_cicd` policy to that user, or drop `withCredentials` and rely on the
instance profile.

## Data pipeline

**Glue job fails: "No input data found in either the batch or streaming prefix"**
Nothing has been uploaded yet. Run:
```bash
python3 scripts/generate_sample_data.py --rows 5000 --upload s3://<raw-bucket>
```

**Glue job fails: "Data quality check FAILED: dropped X% of rows"**
Working as designed — the job refuses to publish bad analytics. Inspect the raw
CSV for nulls, malformed dates, or negative amounts. Loosen the 30% threshold in
`etl_job.py` only if you understand why rows are being dropped.

**Athena: `Table 'orders_summary' does not exist`**
The **curated** crawler hasn't run, or ran before the ETL job. Order matters:
ETL job first, then curated crawler. `scripts/run_pipeline.sh` enforces this.

**Athena queries return 0 rows but the table exists**
The crawler ran before the job wrote output. Re-run the curated crawler.

**Redshift COPY: "S3ServiceException: Access Denied"**
You used the wrong IAM role. It must be the **Redshift** role (trusted by
`redshift.amazonaws.com`), not the Glue role:
```bash
terraform -chdir=terraform output redshift_iam_role_arn
```

**Redshift COPY succeeds but year/month are NULL**
The curated output must **not** be written with Hive-style partition
directories, because COPY reads columns from inside the Parquet files.
`etl_job.py` deliberately writes the curated output unpartitioned.

**No streaming data appears in S3**
Firehose buffers for 60 seconds (or 1 MB) before writing. Wait, then:
```bash
aws s3 ls s3://<raw-bucket>/streaming/ --recursive
aws logs tail /aws/kinesisfirehose/ecommerce-devops --follow
```

## General debugging commands

```bash
# ECS
aws ecs describe-services --cluster ecommerce-devops-cluster --services backend-service
aws ecs describe-tasks --cluster ecommerce-devops-cluster --tasks <task-arn>
aws logs tail /ecs/ecommerce-devops-backend --follow

# ALB target health
aws elbv2 describe-target-health --target-group-arn <arn>

# Glue
aws glue get-job-runs --job-name ecommerce-devops-etl-job --max-results 3
aws logs tail /aws-glue/jobs/error --follow

# Redshift load errors
# (in a SQL client) SELECT * FROM sys_load_error_detail ORDER BY start_time DESC LIMIT 10;
```
