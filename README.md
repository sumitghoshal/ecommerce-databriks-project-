# AWS DevOps + Data Engineering — E-Commerce Platform

End-to-end project combining a containerized e-commerce app (CI/CD, IaC, ECS) with a
batch + streaming data pipeline (Kinesis, Glue, S3 data lake, Redshift, Athena, QuickSight).

```
Developer ──git push──> GitHub ──webhook──> Jenkins
                                              │
                        Build → Test → SonarQube → Docker → Trivy → ECR
                                              │
                                              ▼
                              ECS Fargate (frontend + backend) ── ALB ──> Users
                                              │
                                    orders ───┼───> MongoDB (operational)
                                              └───> Kinesis (analytics)
                                                      │
                                                   Firehose
                                                      ▼
   S3 raw ──> Glue ETL (PySpark) ──> S3 processed ──> S3 curated
                                                      ├──> Athena ──> QuickSight
                                                      └──> Redshift (star schema)
```

## Repository layout

```
ecommerce-devops-platform/
├── README.md
├── Jenkinsfile                  CI/CD pipeline definition
├── .gitignore
│
├── backend/                     Flask API (containerized)
│   ├── app.py                   REST endpoints, Mongo + Kinesis integration
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   ├── Dockerfile               non-root, healthcheck, gunicorn
│   ├── sonar-project.properties
│   └── tests/test_app.py        unit tests (mongomock, no AWS needed)
│
├── frontend/                    Static site served by nginx
│   ├── index.html
│   ├── app.js                   calls /api/* (relative — routed by the ALB)
│   ├── style.css
│   ├── nginx.conf
│   └── Dockerfile
│
├── terraform/                   Infrastructure as Code (15 files)
│   ├── versions.tf              providers + S3 state backend
│   ├── variables.tf
│   ├── terraform.tfvars.example copy to terraform.tfvars and fill in
│   ├── vpc.tf                   VPC, 2 public + 3 private subnets, NAT
│   ├── security_groups.tf       ALB / ECS / Jenkins / Redshift SGs
│   ├── iam.tf                   least-privilege roles for every service
│   ├── kms.tf                   data lake encryption key
│   ├── s3.tf                    raw / processed / curated zones
│   ├── ecr.tf                   image repos + lifecycle policies
│   ├── secrets.tf               Mongo URI in Secrets Manager
│   ├── alb.tf                   ALB, target groups, /api/* routing rule
│   ├── ecs.tf                   cluster, task definitions, services, autoscaling
│   ├── kinesis.tf               stream + Firehose to S3
│   ├── glue.tf                  catalogs, 2 crawlers, PySpark job
│   ├── athena.tf                workgroup + results location
│   ├── redshift.tf              Redshift Serverless namespace + workgroup
│   ├── monitoring.tf            CloudWatch alarms, SNS, EventBridge
│   ├── jenkins.tf               Jenkins EC2 (t3.large)
│   └── outputs.tf               URLs, bucket names, ARNs you'll need
│
├── glue-jobs/
│   └── etl_job.py               PySpark: clean → validate → Parquet → aggregate
│
├── streaming/
│   └── producer.py              Kinesis event producer (simulates traffic)
│
├── sql/
│   ├── 01_create_star_schema.sql
│   ├── 02_load_data.sql         COPY from S3 into Redshift
│   ├── 03_analytics_queries.sql dashboard-backing queries
│   └── 04_athena_queries.sql    data lake queries
│
├── scripts/
│   ├── bootstrap_backend.sh     creates the Terraform state bucket (run first)
│   ├── install_jenkins.sh       EC2 user_data: Jenkins + Docker + Trivy + Sonar
│   ├── generate_sample_data.py  synthetic orders/products/customers
│   ├── deploy.sh                manual build+push+deploy (for the first deploy)
│   └── run_pipeline.sh          runs the data pipeline in the correct order
│
└── docs/
    ├── SETUP.md                 full step-by-step build guide
    ├── JENKINS_SETUP.md         Jenkins UI configuration
    ├── TROUBLESHOOTING.md       common errors and fixes
    └── COSTS.md                 what this costs and how to tear it down
```

## Quick start

```bash
# 0. Prerequisites: AWS CLI configured, Terraform, Docker, an SSH key pair
ssh-keygen -t rsa -b 4096 -f ~/.ssh/devops-project-key -C "devops-project"
cp ~/.ssh/devops-project-key.pub ./devops-project-key.pub

# 1. Create the Terraform state bucket (Terraform can't create its own backend)
./scripts/bootstrap_backend.sh my-unique-suffix ap-south-1
#    then update the backend block in terraform/versions.tf as printed

# 2. Configure your variables
cd terraform
cp terraform.tfvars.example terraform.tfvars
#    edit terraform.tfvars: bucket_suffix, my_ip_cidr, alert_email,
#    mongo_uri, redshift_admin_password

# 3. Provision everything
terraform init
terraform plan -out=tfplan
terraform apply tfplan
cd ..

# 4. First deploy (ECS sits at 0 healthy tasks until a real image exists)
./scripts/deploy.sh ap-south-1

# 5. Open the app
terraform -chdir=terraform output application_url

# 6. Run the data pipeline
./scripts/run_pipeline.sh ap-south-1

# 7. Generate real-time events (optional, separate terminal)
python3 streaming/producer.py \
    --stream "$(terraform -chdir=terraform output -raw kinesis_stream_name)" \
    --rate 3 --duration 300
```

Full detail is in [docs/SETUP.md](docs/SETUP.md). Jenkins configuration is in
[docs/JENKINS_SETUP.md](docs/JENKINS_SETUP.md).

## Instance sizing

| Component | Size | Why |
|---|---|---|
| Jenkins EC2 | **t3.large** (2 vCPU, 8GB) | Jenkins + Docker builds + SonarQube's bundled Elasticsearch. t3.medium OOMs. |
| Backend task | Fargate 0.5 vCPU / 1GB | Gunicorn, 2 workers × 4 threads |
| Frontend task | Fargate 0.25 vCPU / 0.5GB | Static nginx |
| Glue workers | G.1X × 2 | Cheapest worker type that runs Spark comfortably |
| Redshift | Serverless, 8 RPU | No node sizing; pay per RPU-second |
| Kinesis | 1 shard | 1 MB/s in, 2 MB/s out |

## Tear down

This stack is **not** free-tier only — the NAT Gateway (~$32/mo), Redshift, and
Firehose bill continuously.

```bash
cd terraform && terraform destroy
```

Then check the console for leftovers: EBS volumes, Elastic IPs, CloudWatch log
groups, and the Terraform state bucket (which Terraform won't delete). See
[docs/COSTS.md](docs/COSTS.md).
