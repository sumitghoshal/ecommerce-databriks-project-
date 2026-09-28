resource "aws_kinesis_stream" "orders" {
  name             = "${var.project_name}-orders-stream"
  retention_period = 24

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
  shard_count = 1

  tags = { Name = "${var.project_name}-orders-stream" }
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.project_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "to_s3" {
  name        = "${var.project_name}-orders-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.orders.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.raw.arn
    prefix     = "streaming/orders/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    error_output_prefix = "streaming/errors/"

    # Small buffer so demo data lands in S3 quickly (min 60s / 1MB).
    buffering_size     = 1
    buffering_interval = 60
    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_s3.name
    }
  }

  depends_on = [aws_iam_role_policy_attachment.firehose_scoped]
}
