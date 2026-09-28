output "application_url" {
  description = "Open this in a browser to reach the app"
  value       = "http://${aws_lb.app.dns_name}"
}

output "jenkins_url" {
  description = "Jenkins UI (restricted to your IP)"
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "sonarqube_url" {
  value = "http://${aws_instance.jenkins.public_ip}:9000"
}

output "jenkins_ssh_command" {
  value = "ssh -i ~/.ssh/devops-project-key ubuntu@${aws_instance.jenkins.public_ip}"
}

output "ecr_backend_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "raw_bucket" { value = aws_s3_bucket.raw.bucket }
output "processed_bucket" { value = aws_s3_bucket.processed.bucket }
output "curated_bucket" { value = aws_s3_bucket.curated.bucket }

output "kinesis_stream_name" {
  value = aws_kinesis_stream.orders.name
}

output "glue_job_name" { value = aws_glue_job.etl.name }
output "glue_raw_crawler" { value = aws_glue_crawler.raw.name }
output "glue_curated_crawler" { value = aws_glue_crawler.curated.name }

output "redshift_endpoint" {
  value = aws_redshiftserverless_workgroup.main.endpoint[0].address
}

output "redshift_iam_role_arn" {
  description = "Use this ARN in the COPY command (sql/load_data.sql)"
  value       = aws_iam_role.redshift.arn
}

output "athena_workgroup" { value = aws_athena_workgroup.main.name }
output "sns_alerts_topic" { value = aws_sns_topic.alerts.arn }

output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
