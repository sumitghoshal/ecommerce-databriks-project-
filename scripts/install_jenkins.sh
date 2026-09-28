#!/bin/bash
# ===========================================================================
# Jenkins EC2 bootstrap (runs as EC2 user_data on first boot).
# Installs: Java 17, Jenkins, Docker, AWS CLI v2, Trivy, SonarQube container.
#
# Target instance: t3.large (8GB). t3.medium WILL OOM once SonarQube runs.
# ===========================================================================
set -euxo pipefail

exec > >(tee /var/log/jenkins-bootstrap.log) 2>&1
echo "=== Bootstrap started at $(date) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# --- Java 17 (required by Jenkins) -----------------------------------------
apt-get install -y openjdk-17-jdk git curl wget unzip apt-transport-https gnupg lsb-release

# --- Jenkins ----------------------------------------------------------------
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
    | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y
apt-get install -y jenkins

# --- Docker -----------------------------------------------------------------
apt-get install -y docker.io
usermod -aG docker jenkins
usermod -aG docker ubuntu
systemctl enable docker
systemctl restart docker

# --- AWS CLI v2 -------------------------------------------------------------
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# --- Trivy ------------------------------------------------------------------
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
    | gpg --dearmor | tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
    | tee /etc/apt/sources.list.d/trivy.list
apt-get update -y
apt-get install -y trivy

# --- Python tooling for the unit-test stage --------------------------------
apt-get install -y python3-pip python3-venv

# --- SonarQube --------------------------------------------------------------
# CRITICAL: SonarQube bundles Elasticsearch, which refuses to start unless
# vm.max_map_count is raised. Without this the container crash-loops with:
#   "max virtual memory areas vm.max_map_count [65530] is too low"
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -p

docker run -d --name sonarqube --restart unless-stopped \
    -p 9000:9000 \
    -v sonarqube_data:/opt/sonarqube/data \
    -v sonarqube_extensions:/opt/sonarqube/extensions \
    sonarqube:lts-community

# --- Start Jenkins ----------------------------------------------------------
systemctl enable jenkins
systemctl restart jenkins

sleep 30
echo "=== Bootstrap finished at $(date) ==="
echo "Jenkins initial admin password:"
cat /var/lib/jenkins/secrets/initialAdminPassword || echo "(not ready yet — check again in a minute)"
