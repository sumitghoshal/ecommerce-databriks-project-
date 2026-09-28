resource "aws_secretsmanager_secret" "mongo_uri" {
  name                    = "${var.project_name}/mongo-uri"
  description             = "MongoDB connection string for the backend service"
  kms_key_id              = aws_kms_key.data.arn
  recovery_window_in_days = 0 # 0 = delete immediately on destroy (dev only)
}

resource "aws_secretsmanager_secret_version" "mongo_uri" {
  secret_id     = aws_secretsmanager_secret.mongo_uri.id
  secret_string = var.mongo_uri
}
