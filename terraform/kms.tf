resource "aws_kms_key" "data" {
  description             = "${var.project_name} data lake encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.project_name}-data"
  target_key_id = aws_kms_key.data.key_id
}
