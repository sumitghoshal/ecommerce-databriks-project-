data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "jenkins" {
  key_name   = "${var.project_name}-key"
  public_key = file("${path.module}/../devops-project-key.pub")
}

# t3.large, NOT t3.medium: Jenkins + Docker builds + the SonarQube container
# (which bundles Elasticsearch) will OOM on 4GB.
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  key_name               = aws_key_pair.jenkins.key_name
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = file("${path.module}/../scripts/install_jenkins.sh")

  tags = { Name = "${var.project_name}-jenkins" }
}
