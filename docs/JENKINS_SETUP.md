# Jenkins Configuration

The EC2 instance is provisioned by `terraform/jenkins.tf` and bootstrapped by
`scripts/install_jenkins.sh` (runs automatically as user_data). This document
covers the UI configuration you must do by hand afterwards.

## 1. Connect

```bash
terraform -chdir=terraform output jenkins_ssh_command
# ssh -i ~/.ssh/devops-project-key ubuntu@<ip>
```

In MobaXterm: **Session → SSH**, host = the public IP, username = `ubuntu`,
**Advanced SSH settings → Use private key** → `~/.ssh/devops-project-key`.

Verify the bootstrap finished:
```bash
sudo tail -50 /var/log/jenkins-bootstrap.log
sudo systemctl status jenkins
docker ps            # sonarqube should be running
```

## 2. Unlock Jenkins

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<ip>:8080`, paste the password, choose **Install suggested plugins**,
then create your admin user.

## 3. Install additional plugins

**Manage Jenkins → Plugins → Available**:

- Docker Pipeline
- Pipeline: AWS Steps
- SonarQube Scanner
- Amazon ECR

Restart Jenkins when prompted.

## 4. Configure SonarQube (two separate settings — both required)

The `Jenkinsfile` will fail without both of these.

**a) Manage Jenkins → System → SonarQube servers → Add**
- Name: `MySonarQube` — must match `withSonarQubeEnv('MySonarQube')` exactly
- Server URL: `http://<ip>:9000`
- Server authentication token: the `SONAR_TOKEN` credential (created in step 5)

**b) Manage Jenkins → Tools → SonarQube Scanner installations → Add**
- Name: `SonarScanner` — must match `tool 'SonarScanner'` in the Jenkinsfile
- Check **Install automatically**

Without (b), stage 3 fails with `sonar-scanner: command not found`.

## 5. Credentials

First get a SonarQube token: open `http://<ip>:9000` (admin/admin, you'll be
forced to change it) → **My Account → Security → Generate Token**.

**Manage Jenkins → Credentials → System → Global credentials → Add**:

| ID | Kind | Value |
|---|---|---|
| `aws-creds` | AWS Credentials | Access key + secret for a CI IAM user |
| `github-creds` | Username with password | GitHub username + a personal access token |
| `SONAR_TOKEN` | Secret text | The token from SonarQube |

> The Jenkins EC2 instance also has an IAM instance profile (`jenkins.tf`) with
> ECR push and ECS deploy permissions. If you prefer instance-profile auth over
> static keys, remove the `withCredentials` wrappers from the Jenkinsfile.

## 6. Create the pipeline job

**New Item → Pipeline**, name it `ecommerce-pipeline`.

- **Pipeline → Definition**: Pipeline script from SCM
- SCM: Git
- Repository URL: your GitHub repo
- Credentials: `github-creds`
- Branch: `*/main`
- Script Path: `Jenkinsfile`

Save, then **Build Now**.

## 7. Auto-trigger on push

In GitHub: **Settings → Webhooks → Add webhook**
- Payload URL: `http://<ip>:8080/github-webhook/`
- Content type: `application/json`
- Event: Just the push event

In the Jenkins job: **Configure → Build Triggers → GitHub hook trigger for GITScm polling**.

## 8. Before the first build

Edit `Jenkinsfile` and set `AWS_ACCOUNT` to your real account id:

```bash
aws sts get-caller-identity --query Account --output text
```
