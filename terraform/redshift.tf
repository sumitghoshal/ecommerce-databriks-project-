# Redshift Serverless: no node sizing to manage, pay per RPU-second.
# The IAM role attached here is what COPY uses to read from S3 — it must be
# trusted by redshift.amazonaws.com (see iam.tf), NOT the Glue role.
resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "${var.project_name}-ns"
  admin_username      = "admin"
  admin_user_password = var.redshift_admin_password
  db_name             = "ecommercedb"

  iam_roles            = [aws_iam_role.redshift.arn]
  default_iam_role_arn = aws_iam_role.redshift.arn

  kms_key_id = aws_kms_key.data.arn
}

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "${var.project_name}-wg"

  base_capacity = 8 # RPUs — minimum for Redshift Serverless

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.redshift.id]

  publicly_accessible = false
}
