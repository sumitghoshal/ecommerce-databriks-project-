# AWS DevOps + Data Engineering — E-Commerce Platform
## Complete Build Notes (Step-by-Step, With Code)

This document walks through building the **entire architecture** in your diagram, from a developer's laptop (via MobaXterm) all the way to a working CI/CD pipeline, containerized app on ECS/EKS, a streaming + batch data pipeline, a Redshift data warehouse, and dashboards — with monitoring and security wired in.

> Read this top to bottom once, then follow it as a runbook. Each section = one numbered box in your diagram.

---

## 0. High-Level Build Order

You must build things in **dependency order**, not diagram order:

1. AWS account + IAM user + MobaXterm/CLI setup (local tooling)
2. Terraform — networking (VPC) + core AWS resources (Box 3)
3. GitHub repo + app code (Box 1)
4. Docker images + ECR (Box 2 partial, Box 4)
5. Jenkins server + pipeline (Box 2, Box 13)
6. ECS/EKS deployment + Load Balancer + Auto Scaling (Box 4, 5, 6)
7. S3 data lake + Kinesis ingestion (Box 7)
8. AWS Glue ETL jobs (Box 8)
9. Redshift data warehouse + star schema (Box 9)
10. Athena + QuickSight (Box 10)
11. CloudWatch + SNS monitoring (Box 11)
12. IAM / Secrets Manager / KMS hardening (Box 12)

---

## 1. Local Tooling Setup (Your Laptop / MobaXterm)

### 1.1 Install MobaXterm
- Download MobaXterm **Home Edition** (free) from mobaxterm.mobatek.net → Installer edition.
- Install it normally on Windows (Next → Next → Finish).
- Open MobaXterm → this gives you an SSH client + local terminal with Linux-like tools (`ssh`, `scp`, `git`, `curl` all work out of the box in its terminal).

### 1.2 Generate an SSH key pair (used to SSH into EC2 / Jenkins box)
In MobaXterm's local terminal (the "Start local terminal" session):
```bash
mkdir -p ~/.ssh
ssh-keygen -t rsa -b 4096 -f ~/.ssh/devops-project-key -C "devops-project"
# Press Enter twice for no passphrase (or set one, your choice)
chmod 400 ~/.ssh/devops-project-key
cat ~/.ssh/devops-project-key.pub
```
Keep `devops-project-key.pub` — you will import it into AWS as an EC2 Key Pair.

### 1.3 Install AWS CLI v2 (in MobaXterm terminal, it uses a Cygwin/Linux-like shell)
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.msi" -o "AWSCLIV2.msi"
msiexec /i AWSCLIV2.msi
aws --version
```
Configure it with an IAM user's access keys (create this user first in AWS Console → IAM → Users → create `devops-admin` with `AdministratorAccess` for the build phase; you will restrict it later in Section 12):
```bash
aws configure
# AWS Access Key ID: <paste>
# AWS Secret Access Key: <paste>
# Default region name: ap-south-1
# Default output format: json
```

### 1.4 Install Terraform
```bash
# Windows via Chocolatey (run in MobaXterm terminal if choco installed)
choco install terraform -y
terraform -version
```
(If no choco, download the terraform_*_windows_amd64.zip from terraform.io, unzip, add folder to PATH.)

### 1.5 Install Docker Desktop
- Download Docker Desktop for Windows, enable WSL2 backend.
- Verify: `docker --version` and `docker run hello-world` in MobaXterm terminal.

### 1.6 Install kubectl + eksctl (only needed if you deploy to EKS, not ECS)
```bash
choco install kubernetes-cli -y
choco install eksctl -y
kubectl version --client
eksctl version
```

### 1.7 Install Git and create GitHub repo
```bash
git --version
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```
On GitHub.com: create a new repo `ecommerce-devops-platform` (private). Clone it:
```bash
cd ~
git clone https://github.com/<your-username>/ecommerce-devops-platform.git
cd ecommerce-devops-platform
```

---

## 2. EC2 / Compute Sizing Guide (What Size to Pick, Everywhere)

| Component | Instance/Service Size | Why |
|---|---|---|
| Jenkins server (EC2) | **t3.large** (2 vCPU, 8GB) — see note below | Jenkins + Docker builds + a co-located SonarQube container together need more than 4GB; t2/t3.micro will OOM during Docker builds |
| Bastion host (optional, to SSH into private subnet) | **t3.micro** (free-tier eligible) | Just a jump box, no workload |
| ECS EC2 launch type worker nodes (if not using Fargate) | **t3.medium** x2 (min), Auto Scaling 2–4 | Runs your Frontend+Backend containers |
| ECS Fargate (recommended instead of managing EC2) | No EC2 to size — choose Task CPU/Memory: Frontend **0.5 vCPU/1GB**, Backend **0.5 vCPU/1GB** | Serverless containers, no patching, scales per task |
| EKS worker nodes (if using EKS instead of ECS) | **t3.medium** x2–3 managed node group | Same workload as ECS EC2 option |
| MongoDB (self-hosted on EC2, if not using Atlas) | **t3.medium** with 20GB gp3 EBS | Use **MongoDB Atlas free/shared tier** instead for a real project — much less ops work |
| RDS (if used anywhere, e.g. Jenkins metadata or app relational data) | **db.t3.micro** for dev | Free-tier eligible |
| Redshift | **dc2.large** (1–2 nodes) for dev/demo; use **Redshift Serverless** if you want zero node sizing decisions | dc2.large is the cheapest Redshift node type, fine for a learning-scale star schema |
| Kinesis Data Stream | 1 shard (dev) — each shard = 1MB/s in, 2MB/s out | Scale shards later based on throughput needs |

**Recommendation for a solo/demo project:** use **Fargate** for ECS (no EC2 sizing needed for the app), **Redshift Serverless**, and a single **t3.large** EC2 only for Jenkins. This minimizes what you must size/patch yourself.

> **Why t3.large and not t3.medium for Jenkins:** Section 5.4 runs SonarQube as a Docker container on the same box. SonarQube bundles Elasticsearch, which by itself wants ~2GB+ of heap and will refuse to start at all on a stock kernel (see the `vm.max_map_count` fix in Section 5.4). Combine that with Jenkins itself and Docker image builds, and 4GB (t3.medium) runs out fast — you'll see builds randomly killed (OOM-killer) with no clear error. If you want to stay on t3.medium, run SonarQube on its own separate t3.small instead of co-locating it.

### 2.1 Launch the Jenkins EC2 instance manually (Console, quickest path)
1. EC2 → Launch Instance
2. Name: `jenkins-server`
3. AMI: Ubuntu Server 22.04 LTS
4. Instance type: `t3.large` (see sizing note in Section 2 — t3.medium runs out of memory once SonarQube is added)
5. Key pair: import the `.pub` file from Section 1.2 (EC2 → Key Pairs → Import key pair)
6. Network: your project VPC (built in Section 3), public subnet
7. Security group: allow inbound `22` (SSH, your IP only), `8080` (Jenkins UI, your IP only), `443/80` if needed
8. Storage: 30GB gp3
9. Launch.

### 2.2 SSH into it from MobaXterm
- In MobaXterm, click **Session → SSH**
- Remote host: `<EC2 public IP>`
- Username: `ubuntu`
- Advanced SSH settings → Use private key → browse to `~/.ssh/devops-project-key`
- Connect. You now have a full terminal + SFTP file browser (left panel) on the EC2 box.


---

## 3. Terraform — Infrastructure as Code (Box 3)

Create this folder structure in your repo:
```
ecommerce-devops-platform/
  terraform/
    main.tf
    variables.tf
    outputs.tf
    vpc.tf
    iam.tf
    ecr.tf
    ecs.tf
    rds.tf
    redshift.tf
    s3.tf
    cloudwatch.tf
```

### 3.1 `terraform/main.tf`
```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "ecommerce-devops-tfstate-CHANGE-ME"   # must be globally unique
    key    = "global/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.aws_region
}
```
> Create the state bucket **first**, manually, before `terraform init` can use it:
```bash
aws s3api create-bucket --bucket ecommerce-devops-tfstate-CHANGE-ME --region ap-south-1
aws s3api put-bucket-versioning --bucket ecommerce-devops-tfstate-CHANGE-ME --versioning-configuration Status=Enabled
```

### 3.2 `terraform/variables.tf`
```hcl
variable "aws_region" {
  default = "ap-south-1"
}
variable "project_name" {
  default = "ecommerce-devops"
}
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}
```

### 3.3 `terraform/vpc.tf`
```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "${var.project_name}-private-${count.index}" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = { Name = "${var.project_name}-nat" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "ecs_sg" {
  name        = "${var.project_name}-ecs-sg"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### 3.4 `terraform/ecr.tf`
```hcl
resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}
```

### 3.5 `terraform/s3.tf` (data lake zones)
```hcl
resource "aws_s3_bucket" "raw" {
  bucket = "${var.project_name}-raw-zone-CHANGE-ME"
}
resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-zone-CHANGE-ME"
}
resource "aws_s3_bucket" "curated" {
  bucket = "${var.project_name}-curated-zone-CHANGE-ME"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_enc" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
```

### 3.6 `terraform/iam.tf` (least-privilege roles referenced later)
```hcl
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "glue_role" {
  name = "${var.project_name}-glue-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy_attachment" "glue_s3" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"   # tighten later — see Section 12
}
```

### 3.7 `terraform/outputs.tf`
```hcl
output "vpc_id" { value = aws_vpc.main.id }
output "ecr_frontend_url" { value = aws_ecr_repository.frontend.repository_url }
output "ecr_backend_url" { value = aws_ecr_repository.backend.repository_url }
output "raw_bucket" { value = aws_s3_bucket.raw.bucket }
output "processed_bucket" { value = aws_s3_bucket.processed.bucket }
output "curated_bucket" { value = aws_s3_bucket.curated.bucket }
```

### 3.8 Run it
```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```
Note the outputs (ECR URLs, bucket names) — you'll need them below.


---

## 4. Application Code + Dockerfiles (Box 1, 4, 6)

### 4.1 Repo layout
```
ecommerce-devops-platform/
  frontend/        # HTML/CSS/JS
    Dockerfile
    index.html
    style.css
    app.js
  backend/         # Flask
    Dockerfile
    app.py
    requirements.txt
  Jenkinsfile
  terraform/        (from Section 3)
  glue-jobs/         (Section 8)
  sql/               (Section 9)
```

### 4.2 `backend/app.py` (minimal Flask API talking to MongoDB)
```python
from flask import Flask, jsonify, request
from pymongo import MongoClient
import os

app = Flask(__name__)
client = MongoClient(os.environ.get("MONGO_URI", "mongodb://localhost:27017"))
db = client.ecommerce

@app.route("/health")
def health():
    return jsonify(status="ok")

@app.route("/api/orders", methods=["GET"])
def get_orders():
    orders = list(db.orders.find({}, {"_id": 0}))
    return jsonify(orders)

@app.route("/api/orders", methods=["POST"])
def create_order():
    order = request.get_json()
    db.orders.insert_one(order)
    return jsonify(status="created"), 201

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

### 4.3 `backend/requirements.txt`
```
flask==3.0.3
pymongo==4.8.0
boto3==1.34.144
gunicorn==22.0.0
```

### 4.4 `backend/Dockerfile`
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["gunicorn", "-b", "0.0.0.0:5000", "app:app"]
```

### 4.5 `frontend/index.html` (minimal, calls the backend API)
```html
<!DOCTYPE html>
<html>
<head><title>E-Commerce Store</title><link rel="stylesheet" href="style.css"></head>
<body>
  <h1>My Store</h1>
  <div id="orders"></div>
  <script src="app.js"></script>
</body>
</html>
```

### 4.5a `frontend/app.js` — calls the backend through the SAME domain, path `/api/*`
This matters: the frontend and backend are two separate containers/services. The frontend
JS must NOT call `localhost:5000` (that doesn't exist in the browser's context) — it calls
a **relative** `/api/...` path, and the ALB (Section 6.1) routes that path to the backend
target group while `/` goes to the frontend. This is why Section 6's ALB listener rule
for `/api/*` exists.
```javascript
async function loadOrders() {
  const res = await fetch("/api/orders");
  const orders = await res.json();
  const container = document.getElementById("orders");
  container.innerHTML = orders
    .map(o => `<div>Order ${o.order_id} — $${o.amount}</div>`)
    .join("");
}
loadOrders();
```

### 4.5b `frontend/style.css`
```css
body { font-family: sans-serif; margin: 2rem; }
h1 { color: #1e3a5f; }
#orders div { padding: 0.5rem; border-bottom: 1px solid #ddd; }
```

### 4.6 `frontend/Dockerfile` (served via nginx)
```dockerfile
FROM nginx:alpine
COPY . /usr/share/nginx/html
EXPOSE 80
```

### 4.7 Build & test locally
```bash
cd backend
docker build -t ecommerce-backend .
docker run -p 5000:5000 ecommerce-backend

cd ../frontend
docker build -t ecommerce-frontend .
docker run -p 8081:80 ecommerce-frontend
```

### 4.8 Push to GitHub
```bash
cd ecommerce-devops-platform
git add .
git commit -m "Initial app + terraform + dockerfiles"
git push origin main
```


---

## 5. Jenkins Setup + CI/CD Pipeline (Box 2, Box 13)

### 5.1 Install Jenkins on the EC2 box (SSH in via MobaXterm first — Section 2.2)
```bash
sudo apt update && sudo apt upgrade -y

# Java (required by Jenkins)
sudo apt install -y openjdk-17-jdk

# Jenkins repo + install
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install -y jenkins

sudo systemctl enable jenkins
sudo systemctl start jenkins
sudo systemctl status jenkins
```

### 5.2 Install Docker on the Jenkins box (Jenkins needs it to build images)
```bash
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
sudo systemctl restart docker
sudo systemctl restart jenkins
```

### 5.3 Install AWS CLI + Trivy + SonarScanner on the Jenkins box
```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt install -y unzip
unzip awscliv2.zip
sudo ./aws/install

# Trivy (security scan)
sudo apt install -y wget apt-transport-https gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | \
  sudo tee -a /etc/apt/sources.list.d/trivy.list
sudo apt update && sudo apt install -y trivy
```
> SonarQube: easiest path is to run it as its own Docker container (see 5.4) rather than installing natively — it needs its own JVM tuning.

### 5.4 Run SonarQube as a container on the same box (or a separate small EC2)

**Do this first, or the container will crash-loop.** SonarQube bundles Elasticsearch,
which performs a kernel bootstrap check on startup and refuses to run if
`vm.max_map_count` is too low. On a stock Ubuntu 22.04 EC2 instance it is — you'll
see the container exit immediately with `max virtual memory areas vm.max_map_count
[65530] is too low, increase to at least [262144]` in `docker logs sonarqube`.
```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf   # persist across reboots

docker run -d --name sonarqube -p 9000:9000 sonarqube:lts-community
```
Check it actually came up before moving on:
```bash
docker logs -f sonarqube   # wait for "SonarQube is operational"
```
Access `http://<EC2-IP>:9000` (default admin/admin, forces password reset).
Generate a token: SonarQube UI → My Account → Security → Generate Token → save it as a Jenkins credential (`SONAR_TOKEN`).

### 5.5 Unlock Jenkins & install plugins
1. Browse to `http://<EC2-IP>:8080`
2. Get the initial admin password:
```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```
3. Install suggested plugins, then also install from **Manage Jenkins → Plugins**:
   - Docker Pipeline
   - Amazon ECR
   - Pipeline: AWS Steps
   - SonarQube Scanner
   - Git

**Two settings the Jenkinsfile below silently depends on — don't skip these:**
1. **Manage Jenkins → System → SonarQube servers** → add one named exactly `MySonarQube`, URL `http://<EC2-IP>:9000`, and pick the `SONAR_TOKEN` credential from 5.6. This name must match `withSonarQubeEnv('MySonarQube')` in the Jenkinsfile.
2. **Manage Jenkins → Tools → SonarQube Scanner installations** → add one (any name), check "Install automatically." Without this, the `sonar-scanner` command in the Jenkinsfile won't exist on the agent and stage 3 fails with `command not found`.

### 5.6 Add Jenkins credentials (Manage Jenkins → Credentials → Global)
| ID | Type | Value |
|---|---|---|
| `aws-creds` | AWS Credentials | access key / secret key of a CI IAM user |
| `github-creds` | Username/password or SSH key | GitHub access |
| `SONAR_TOKEN` | Secret text | token from 5.4 |

### 5.7 `Jenkinsfile` (put this at repo root — drives Boxes 2 and 13)
```groovy
pipeline {
    agent any

    environment {
        AWS_REGION       = "ap-south-1"
        ECR_BACKEND_URL  = "<account-id>.dkr.ecr.ap-south-1.amazonaws.com/ecommerce-devops-backend"
        ECR_FRONTEND_URL = "<account-id>.dkr.ecr.ap-south-1.amazonaws.com/ecommerce-devops-frontend"
        IMAGE_TAG        = "${env.BUILD_NUMBER}"
    }

    stages {
        stage('1. Checkout') {
            steps {
                git branch: 'main', url: 'https://github.com/<your-username>/ecommerce-devops-platform.git'
            }
        }

        stage('2. Build & Unit Test') {
            steps {
                sh '''
                  cd backend && python3 -m pip install -r requirements.txt --quiet
                  echo "run unit tests here e.g. pytest"
                '''
            }
        }

        stage('3. SonarQube Code Quality') {
            steps {
                withSonarQubeEnv('MySonarQube') {
                    sh 'sonar-scanner -Dsonar.projectKey=ecommerce-backend -Dsonar.sources=backend'
                }
            }
        }

        stage('4. Docker Build') {
            steps {
                sh '''
                  docker build -t $ECR_BACKEND_URL:$IMAGE_TAG -t $ECR_BACKEND_URL:latest ./backend
                  docker build -t $ECR_FRONTEND_URL:$IMAGE_TAG -t $ECR_FRONTEND_URL:latest ./frontend
                '''
            }
        }

        stage('5. Trivy Security Scan') {
            steps {
                sh '''
                  trivy image --exit-code 0 --severity HIGH,CRITICAL $ECR_BACKEND_URL:$IMAGE_TAG
                  trivy image --exit-code 0 --severity HIGH,CRITICAL $ECR_FRONTEND_URL:$IMAGE_TAG
                '''
            }
        }

        stage('6. Push to ECR') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
                    sh '''
                      aws ecr get-login-password --region $AWS_REGION | \
                        docker login --username AWS --password-stdin $ECR_BACKEND_URL
                      docker push $ECR_BACKEND_URL:$IMAGE_TAG
                      docker push $ECR_BACKEND_URL:latest
                      docker push $ECR_FRONTEND_URL:$IMAGE_TAG
                      docker push $ECR_FRONTEND_URL:latest
                    '''
                }
            }
        }

        stage('7. Deploy to ECS') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
                    sh '''
                      aws ecs update-service --cluster ecommerce-cluster \
                        --service backend-service --force-new-deployment --region $AWS_REGION
                      aws ecs update-service --cluster ecommerce-cluster \
                        --service frontend-service --force-new-deployment --region $AWS_REGION
                    '''
                }
            }
        }
    }

    post {
        success { echo "Pipeline succeeded — deployed build $IMAGE_TAG" }
        failure { echo "Pipeline failed — check stage logs" }
    }
}
```
Create the Jenkins job: **New Item → Pipeline → Pipeline script from SCM → Git → your repo → Jenkinsfile path: `Jenkinsfile`**. Add a GitHub webhook (repo → Settings → Webhooks → `http://<EC2-IP>:8080/github-webhook/`) so pushes auto-trigger builds.

**Why the pipeline pushes both `:$IMAGE_TAG` and `:latest`:** the ECS task definitions in Section 6 pull `:latest` (simplest approach for a demo). `force-new-deployment` in stage 7 doesn't change *which* image tag a service uses — it just makes ECS re-pull whatever tag the task definition already points to. If the pipeline only pushed the build-number tag, `:latest` would never update and every deploy would silently redeploy stale (or missing) code. Bootstrap order matters here too: run `terraform apply` (Section 3.8/6.1) **before** the first Jenkins build — the ECS services will show 0 healthy tasks and keep retrying until that first pipeline run pushes a real `:latest` image, which is expected and resolves itself once the pipeline succeeds once.


---

## 6. ECS Deployment + Load Balancer + Auto Scaling (Box 4, 5, 6)

> Using **ECS Fargate** (no EC2 nodes to manage) — matches the sizing recommendation in Section 2.

### 6.1 `terraform/ecs.tf`
```hcl
resource "aws_ecs_cluster" "main" {
  name = "ecommerce-cluster"
}

resource "aws_lb" "app_alb" {
  name               = "ecommerce-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "frontend_tg" {
  name        = "frontend-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "backend-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions = jsonencode([{
    name  = "backend"
    image = "${aws_ecr_repository.backend.repository_url}:latest"
    portMappings = [{ containerPort = 5000, protocol = "tcp" }]
    environment = [{ name = "MONGO_URI", value = "<your-mongo-atlas-uri>" }]
  }])
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "frontend-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions = jsonencode([{
    name  = "frontend"
    image = "${aws_ecr_repository.frontend.repository_url}:latest"
    portMappings = [{ containerPort = 80, protocol = "tcp" }]
  }])
}

resource "aws_lb_target_group" "backend_tg" {
  name        = "backend-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health" }
}

resource "aws_lb_listener_rule" "backend_route" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
  condition {
    path_pattern { values = ["/api/*"] }
  }
}

# Same SG is used for the ALB and both services (simple for a demo). This
# self-referencing rule is what actually lets the ALB reach task port 5000 —
# without it, the backend target group health checks fail and /api/* 502s.
resource "aws_security_group_rule" "ecs_sg_self_backend" {
  type                     = "ingress"
  from_port                = 5000
  to_port                  = 5000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_sg.id
  source_security_group_id = aws_security_group.ecs_sg.id
}

resource "aws_ecs_service" "backend" {
  name            = "backend-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.backend_tg.arn
    container_name    = "backend"
    container_port    = 5000
  }
}

resource "aws_ecs_service" "frontend" {
  name            = "frontend-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.frontend_tg.arn
    container_name    = "frontend"
    container_port    = 80
  }
}

# Auto Scaling (Box 6)
resource "aws_appautoscaling_target" "backend_scaling" {
  max_capacity       = 6
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "backend_cpu_scaling" {
  name               = "backend-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.backend_scaling.resource_id
  scalable_dimension = aws_appautoscaling_target.backend_scaling.scalable_dimension
  service_namespace  = aws_appautoscaling_target.backend_scaling.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
```
Apply it:
```bash
cd terraform
terraform apply
```
After the first Jenkins pipeline run pushes real images (Section 5), re-run `terraform apply` or let Jenkins stage 7 (`update-service --force-new-deployment`) pick up `:latest`.

Get the app URL:
```bash
terraform output   # or
aws elbv2 describe-load-balancers --names ecommerce-alb --query 'LoadBalancers[0].DNSName'
```


---

## 7. Data Ingestion — Batch (S3) + Streaming (Kinesis) (Box 7)

### 7.1 Batch: upload CSV/JSON order data to S3 raw zone
```bash
aws s3 cp orders_2026_09.csv s3://<raw-bucket-name>/batch/orders/
aws s3 cp customers.json s3://<raw-bucket-name>/batch/customers/
```
In production, your backend (or a scheduled job) would `PUT` files here; for a demo, generate sample CSVs and upload with the CLI as above.

### 7.2 Streaming: create a Kinesis Data Stream
```hcl
# terraform/kinesis.tf
resource "aws_kinesis_stream" "orders_stream" {
  name             = "ecommerce-orders-stream"
  shard_count      = 1
  retention_period = 24
}
```
```bash
terraform apply
```

### 7.3 Producer script — simulates real-time order/click events (Python, boto3)
`streaming/producer.py`
```python
import boto3
import json
import random
import time
import uuid

kinesis = boto3.client("kinesis", region_name="ap-south-1")
STREAM_NAME = "ecommerce-orders-stream"

def generate_event():
    return {
        "event_id": str(uuid.uuid4()),
        "customer_id": random.randint(1, 500),
        "product_id": random.randint(1, 100),
        "event_type": random.choice(["view", "add_to_cart", "purchase"]),
        "amount": round(random.uniform(5, 300), 2),
        "timestamp": time.time(),
    }

if __name__ == "__main__":
    while True:
        event = generate_event()
        kinesis.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(event),
            PartitionKey=str(event["customer_id"]),
        )
        print("sent:", event)
        time.sleep(1)
```
Run it (from your laptop, MobaXterm terminal, with `aws configure` credentials set):
```bash
pip install boto3
python streaming/producer.py
```

### 7.4 Deliver the stream into S3 raw zone via Kinesis Data Firehose
```hcl
# terraform/firehose.tf
resource "aws_iam_role" "firehose_role" {
  name = "${var.project_name}-firehose-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "firehose_s3" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"  # tighten in Section 12
}

resource "aws_kinesis_firehose_delivery_stream" "to_s3" {
  name        = "orders-stream-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.orders_stream.arn
    role_arn            = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.raw.arn
    prefix     = "streaming/orders/"
  }
}
```


---

## 8. AWS Glue ETL (PySpark) — Box 8

### 8.1 Create a Glue Data Catalog database + crawler (Terraform)
```hcl
# terraform/glue.tf
resource "aws_glue_catalog_database" "raw_db" {
  name = "ecommerce_raw_db"
}

resource "aws_glue_crawler" "raw_crawler" {
  name          = "ecommerce-raw-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.raw_db.name
  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/batch/"
  }
}

# Catalogs the ETL job's aggregated output so Athena/QuickSight can query it —
# without this, Section 10's queries have no table to read from.
resource "aws_glue_catalog_database" "curated_db" {
  name = "ecommerce_curated_db"
}

resource "aws_glue_crawler" "curated_crawler" {
  name          = "ecommerce-curated-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.curated_db.name
  s3_target {
    path = "s3://${aws_s3_bucket.curated.bucket}/orders_summary/"
  }
}

resource "aws_glue_job" "etl_job" {
  name     = "ecommerce-etl-job"
  role_arn = aws_iam_role.glue_role.arn
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.processed.bucket}/scripts/etl_job.py"
    python_version  = "3"
  }
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  default_arguments = {
    "--job-language"                    = "python"
    "--RAW_BUCKET"                      = aws_s3_bucket.raw.bucket
    "--PROCESSED_BUCKET"                = aws_s3_bucket.processed.bucket
    "--CURATED_BUCKET"                  = aws_s3_bucket.curated.bucket
    "--enable-metrics"                  = "true"
  }
}
```
**Worker sizing note:** `G.1X` (4 vCPU, 16GB, 1 DPU) x2 workers is the right dev-scale choice — cheapest Glue worker type that still runs Spark comfortably. Don't use `G.2X`/`G.025X` unless you know you need bigger/smaller.

### 8.2 `glue-jobs/etl_job.py` (PySpark, data cleaning → transform → Parquet → quality checks)
```python
import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["JOB_NAME", "RAW_BUCKET", "PROCESSED_BUCKET", "CURATED_BUCKET"])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

RAW_BUCKET       = args["RAW_BUCKET"]
PROCESSED_BUCKET = args["PROCESSED_BUCKET"]
CURATED_BUCKET   = args["CURATED_BUCKET"]

# 1. Read raw batch orders (CSV)
orders_df = spark.read.option("header", "true").csv(f"s3://{RAW_BUCKET}/batch/orders/")

# 2. Data cleaning: drop nulls in required fields, dedupe
clean_df = (
    orders_df
    .dropna(subset=["order_id", "customer_id", "product_id", "amount"])
    .dropDuplicates(["order_id"])
)

# 3. Data transformation: cast types, derive columns
transformed_df = (
    clean_df
    .withColumn("amount", F.col("amount").cast("double"))
    .withColumn("order_date", F.to_date("order_date"))
    .withColumn("year", F.year("order_date"))
    .withColumn("month", F.month("order_date"))
)

# 4. Data quality checks — fail the job if quality bar isn't met
total_rows = transformed_df.count()
null_amounts = transformed_df.filter(F.col("amount").isNull()).count()
if total_rows == 0:
    raise Exception("Data quality check failed: 0 rows after cleaning")
if null_amounts / total_rows > 0.05:
    raise Exception(f"Data quality check failed: {null_amounts}/{total_rows} null amounts")

# 5. Write cleaned data to "processed" zone
transformed_df.write.mode("overwrite").parquet(f"s3://{PROCESSED_BUCKET}/orders/")

# 6. Build curated, analytics-ready aggregate and write as Parquet, partitioned
curated_df = (
    transformed_df
    .groupBy("year", "month", "product_id")
    .agg(
        F.sum("amount").alias("total_revenue"),
        F.count("order_id").alias("order_count"),
    )
)
curated_df.write.mode("overwrite").partitionBy("year", "month").parquet(
    f"s3://{CURATED_BUCKET}/orders_summary/"
)

job.commit()
```

### 8.3 Upload the script and run the crawlers + job
```bash
aws s3 cp glue-jobs/etl_job.py s3://<processed-bucket-name>/scripts/etl_job.py
aws glue start-crawler --name ecommerce-raw-crawler
aws glue start-job-run --job-name ecommerce-etl-job
# wait for the job to finish (check status below), THEN crawl its output:
aws glue get-job-runs --job-name ecommerce-etl-job
aws glue start-crawler --name ecommerce-curated-crawler
```
Run the curated crawler **after** the job finishes — it's crawling the job's output, so if you run it first it'll find nothing (or a stale table from a previous run).


---

## 9. Redshift Data Warehouse — Star Schema (Box 9)

### 9.1 Provision Redshift (Terraform) — Redshift Serverless recommended for dev
```hcl
# terraform/redshift.tf
resource "aws_redshiftserverless_namespace" "main" {
  namespace_name       = "ecommerce-ns"
  admin_username       = "admin"
  admin_user_password  = var.redshift_admin_password
  db_name              = "ecommercedb"
  iam_role_arns        = [aws_iam_role.redshift_role.arn]
  default_iam_role_arn = aws_iam_role.redshift_role.arn
}

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "ecommerce-wg"
  base_capacity  = 8   # RPUs — smallest usable size for dev
  subnet_ids     = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.ecs_sg.id]
}

# IMPORTANT FIX: the Glue role from Section 3.6 is only trusted by
# glue.amazonaws.com — Redshift's COPY command cannot assume it. Redshift
# needs its own role, trusted by redshift.amazonaws.com, attached to the
# namespace itself (not passed at query time).
resource "aws_iam_role" "redshift_role" {
  name = "${var.project_name}-redshift-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "redshift.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "redshift_s3_read" {
  role       = aws_iam_role.redshift_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}
```
> `redshift_role` must be declared **before** `aws_redshiftserverless_namespace.main` in the file (Terraform resolves the dependency graph either way, but put it above for readability). If you already ran `terraform apply` with the old version, re-run `terraform apply` again after this fix — it will update the namespace in place, no destroy needed.
> If you'd rather use classic provisioned Redshift: a single **dc2.large** node (from the sizing table in Section 2) is the cheapest option and enough for a demo star schema.

Add the password variable:
```hcl
# variables.tf
variable "redshift_admin_password" {
  sensitive = true
}
```
```bash
terraform apply -var="redshift_admin_password=<StrongPassword123!>"
```

### 9.2 Star schema DDL — `sql/create_star_schema.sql`

**Corrected to match reality:** the Glue job (Section 8.2) outputs an aggregate
(`year`, `month`, `product_id`, `total_revenue`, `order_count`) — it does **not**
produce row-level orders with `order_id`/`customer_id`/`quantity`. A `fact_sales`
table with those columns has nothing valid to `COPY` into it. `dim_customer` and
`dim_date` below are kept because they're standard star-schema pieces you'll want
once you pipe in row-level order data (e.g. from MongoDB via a separate Glue job) —
but they are **not** populated by anything in this document. The fact table that
this pipeline actually feeds is `fact_sales_monthly`, at (year, month, product_id) grain.
```sql
CREATE TABLE dim_customer (
    customer_id     INT PRIMARY KEY,
    customer_name   VARCHAR(200),
    email           VARCHAR(200),
    city            VARCHAR(100),
    signup_date     DATE
);

CREATE TABLE dim_product (
    product_id      INT PRIMARY KEY,
    product_name    VARCHAR(200),
    category        VARCHAR(100),
    unit_price      DECIMAL(10,2)
);

CREATE TABLE dim_date (
    date_id         INT PRIMARY KEY,
    full_date       DATE,
    year            INT,
    month           INT,
    day             INT,
    weekday         VARCHAR(10)
);

-- This is the table the Glue job in Section 8 actually populates.
CREATE TABLE fact_sales_monthly (
    year            INT,
    month           INT,
    product_id      INT REFERENCES dim_product(product_id),
    total_revenue   DECIMAL(12,2),
    order_count     INT
)
DISTKEY(product_id)
SORTKEY(year, month);
```
Connect and run it (via `psql` or the Redshift Query Editor v2 in the AWS Console):
```bash
psql -h <redshift-workgroup-endpoint> -U admin -d ecommercedb -p 5439 -f sql/create_star_schema.sql
```

### 9.3 Load curated S3 data into Redshift with `COPY`
```sql
COPY fact_sales_monthly
FROM 's3://<curated-bucket-name>/orders_summary/'
IAM_ROLE 'arn:aws:iam::<account-id>:role/ecommerce-devops-redshift-role'
FORMAT AS PARQUET;
```
(Get the exact ARN with `terraform output` after adding an output for `aws_iam_role.redshift_role.arn`, or `aws iam get-role --role-name ecommerce-devops-redshift-role`.)

**If you want a true row-level `fact_sales` later:** populate it from the **processed** bucket instead (Section 8.2's `transformed_df` output, which does have `order_id`/`customer_id`/`product_id`/`amount`/`order_date`) — you'd still need to derive a `date_id` and add a `quantity` column upstream (in the source CSV or the PySpark script) before that `COPY` would work; `order_date` alone can't populate `date_id` without either a lookup join against `dim_date` in the ETL script or a Redshift-side join at load time.

---

## 10. Athena + QuickSight (Box 10)

### 10.1 Athena — query the data lake directly (no loading needed)
```sql
-- Run in Athena Query Editor, database = ecommerce_curated_db
-- (from the curated crawler, Section 8.1/8.3 — NOT ecommerce_raw_db, which
-- only catalogs the raw/batch/ input, not the ETL job's output)
SELECT product_id, SUM(total_revenue) AS total_revenue, SUM(order_count) AS order_count
FROM "ecommerce_curated_db"."orders_summary"
GROUP BY product_id
ORDER BY total_revenue DESC
LIMIT 10;
```
Set an Athena query results bucket first (Console → Athena → Settings → Query result location = `s3://<curated-bucket-name>/athena-results/`).

### 10.2 QuickSight dashboards
1. AWS Console → QuickSight → Sign up (Enterprise or Standard edition; Standard is enough for dev).
2. **Manage QuickSight → Security & permissions** → grant access to Athena and the S3 buckets (raw/processed/curated).
3. **New dataset → Athena** → choose `ecommerce_curated_db` → the `orders_summary` table.
4. Build visuals (columns available: `year`, `month`, `product_id`, `total_revenue`, `order_count` — there's no `customer_id` or per-order `amount` in this table, since it's a monthly-by-product aggregate):
   - **Total Revenue** → KPI visual, `SUM(total_revenue)`
   - **Total Orders** → KPI visual, `SUM(order_count)`
   - **Revenue by Product** → Bar chart, `product_id` vs `SUM(total_revenue)`
   - **Sales Trend** → Line chart, `year`+`month` (X) vs `SUM(total_revenue)` (Y)
   - **Top Customers** → not buildable from this table as-is; needs row-level order data with `customer_id` (see the note at the end of Section 9.3 about extending the pipeline with row-level `fact_sales`)
5. Publish as a dashboard, share with your team/stakeholders.

---

## 11. Monitoring & Alerting (Box 11)

### 11.1 CloudWatch alarms + SNS (Terraform)
```hcl
# terraform/monitoring.tf
resource "aws_sns_topic" "alerts" {
  name = "ecommerce-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "you@example.com"   # confirm via the email AWS sends
}

resource "aws_cloudwatch_metric_alarm" "ecs_high_cpu" {
  alarm_name          = "ecs-backend-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.backend.name
  }
}

resource "aws_cloudwatch_metric_alarm" "glue_job_failure" {
  alarm_name          = "glue-etl-job-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_log_group" "backend_logs" {
  name              = "/ecs/ecommerce-backend"
  retention_in_days = 14
}
```
Apply, then confirm the SNS email subscription (check inbox for "AWS Notification - Subscription Confirmation").

### 11.2 What gets monitored (matches diagram Box 11)
- ECS/EKS service CPU/Memory → CloudWatch Container Insights
- Glue job success/failure → CloudWatch metrics + SNS
- Lambda errors (if you add Lambdas later) → CloudWatch Logs + alarms
- Kinesis `IncomingRecords`/`IteratorAgeMilliseconds` → catch consumer lag
- Redshift query performance → CloudWatch `RedshiftServerless` metrics
- Application logs → `/ecs/ecommerce-backend` log group above


---

## 12. Security & Access Hardening (Box 12)

Do this **after** everything works with broad permissions — tightening first makes debugging much harder.

### 12.1 Replace wildcard S3 policies with least-privilege (example for the Glue role)
```hcl
resource "aws_iam_policy" "glue_s3_scoped" {
  name = "glue-s3-scoped-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.raw.arn, "${aws_s3_bucket.raw.arn}/*",
        aws_s3_bucket.processed.arn, "${aws_s3_bucket.processed.arn}/*",
        aws_s3_bucket.curated.arn, "${aws_s3_bucket.curated.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_scoped_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.glue_s3_scoped.arn
}
```
Then remove the `AmazonS3FullAccess` attachments from Sections 3.6 and 7.4 (`glue_role` and `firehose_role`), and repeat the same scoped-policy pattern for `firehose_role` (it only ever needs `PutObject`/`ListBucket` on `aws_s3_bucket.raw`, not all three buckets).

### 12.2 Secrets Manager — store the MongoDB URI / Redshift password (don't hardcode them)
```hcl
resource "aws_secretsmanager_secret" "mongo_uri" {
  name = "ecommerce/mongo-uri"
}
resource "aws_secretsmanager_secret_version" "mongo_uri_val" {
  secret_id     = aws_secretsmanager_secret.mongo_uri.id
  secret_string = "<your-mongo-atlas-uri>"
}
```
Reference it from the ECS task definition instead of a plain `environment` var:
```hcl
container_definitions = jsonencode([{
  name  = "backend"
  image = "${aws_ecr_repository.backend.repository_url}:latest"
  secrets = [{
    name      = "MONGO_URI"
    valueFrom = aws_secretsmanager_secret.mongo_uri.arn
  }]
}])
```
(Grant the ECS execution role `secretsmanager:GetSecretValue` on that secret ARN.)

### 12.3 KMS — encrypt data at rest
```hcl
resource "aws_kms_key" "data_key" {
  description             = "KMS key for ecommerce data lake"
  deletion_window_in_days = 7
}

resource "aws_s3_bucket_server_side_encryption_configuration" "curated_kms" {
  bucket = aws_s3_bucket.curated.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data_key.arn
    }
  }
}
```

### 12.4 Security group / network hardening checklist
- [ ] Jenkins SG: port 8080/22 restricted to **your IP only**, not `0.0.0.0/0`
- [ ] ECS tasks run in **private subnets**, only the ALB is public
- [ ] Redshift workgroup security group: only allow inbound 5439 from your VPC/bastion, not the internet
- [ ] S3 buckets: block all public access (`aws_s3_bucket_public_access_block`)
- [ ] Enable **VPC Flow Logs** for network audit trail
- [ ] Enable **AWS WAF** on the ALB if the app is internet-facing (optional but in the diagram)

```hcl
resource "aws_s3_bucket_public_access_block" "raw_block" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### 12.5 Replace your `devops-admin` IAM user with scoped users
- Create separate IAM users/roles: `ci-cd-deployer` (Jenkins), `data-engineer` (Glue/Redshift), `read-only-analyst` (Athena/QuickSight only).
- Attach only the managed/custom policies each actually needs — never reuse `AdministratorAccess` past the build phase.

---

## 13. Full Runbook Checklist (Execution Order)

- [ ] 1. Install MobaXterm, AWS CLI, Terraform, Docker, Git (Section 1)
- [ ] 2. Create IAM admin user for setup; `aws configure`
- [ ] 3. Create Terraform state S3 bucket manually
- [ ] 4. `terraform init && terraform apply` for VPC + IAM + ECR + S3 + ECS + Redshift + Kinesis + monitoring (Sections 3, 6, 7.2, 9.1, 11.1)
- [ ] 5. Push app code + Dockerfiles to GitHub (Section 4)
- [ ] 6. Launch Jenkins EC2 (t3.large), SSH in via MobaXterm (Section 2)
- [ ] 7. Install Jenkins, Docker, Trivy, SonarQube container, AWS CLI on that box (Section 5)
- [ ] 8. Configure Jenkins credentials + Jenkinsfile pipeline + GitHub webhook (Section 5)
- [ ] 9. Trigger first pipeline run → images land in ECR → ECS services deploy (Section 5, 6)
- [ ] 10. Verify app via ALB DNS name in browser
- [ ] 11. Upload/generate batch data to S3 raw zone; run the Kinesis producer for streaming data (Section 7)
- [ ] 12. Run Glue raw crawler + Glue ETL job, then run the curated crawler → check processed/curated S3 zones and the `ecommerce_curated_db` catalog (Section 8)
- [ ] 13. Create Redshift star schema (`fact_sales_monthly` + dims), `COPY` curated data in (Section 9)
- [ ] 14. Query via Athena against `ecommerce_curated_db`; build QuickSight dashboards (Section 10)
- [ ] 15. Confirm SNS email, verify CloudWatch alarms fire on test load (Section 11)
- [ ] 16. Harden IAM, add Secrets Manager + KMS, lock down security groups (Section 12)
- [ ] 17. Document architecture + take screenshots for your portfolio/resume

## 14. Cost & Cleanup

This project is **not free-tier only** (NAT Gateway, Redshift, Kinesis Firehose all cost money by the hour). To avoid surprise bills:
- Use **Redshift Serverless** (pay per RPU-second) and pause/delete when not demoing.
- Tear everything down when done:
```bash
cd terraform
terraform destroy
```
- Manually double-check the Console afterward for: leftover EBS volumes, NAT Gateways, Elastic IPs, CloudWatch Log Groups, and the S3 state bucket (Terraform won't delete itself) — these are the most common sources of leftover charges.

---

*End of notes. Follow Section 13 top to bottom; each numbered step links back to the section with the full code.*
