# ---------------------------------------------------------------------------
# ECS task execution role: pulls images from ECR, writes logs, reads secrets
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The execution role needs explicit permission to read the secret referenced
# by the task definition, otherwise tasks fail at startup with ResourceInitializationError.
data "aws_iam_policy_document" "ecs_read_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.mongo_uri.arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
  }
}

resource "aws_iam_policy" "ecs_read_secrets" {
  name   = "${var.project_name}-ecs-read-secrets"
  policy = data.aws_iam_policy_document.ecs_read_secrets.json
}

resource "aws_iam_role_policy_attachment" "ecs_read_secrets" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_read_secrets.arn
}

# ---------------------------------------------------------------------------
# ECS TASK role (distinct from the execution role): what the app itself can do
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "app_kinesis_write" {
  statement {
    actions   = ["kinesis:PutRecord", "kinesis:PutRecords"]
    resources = [aws_kinesis_stream.orders.arn]
  }
}

resource "aws_iam_policy" "app_kinesis_write" {
  name   = "${var.project_name}-app-kinesis-write"
  policy = data.aws_iam_policy_document.app_kinesis_write.json
}

resource "aws_iam_role_policy_attachment" "app_kinesis_write" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.app_kinesis_write.arn
}

# ---------------------------------------------------------------------------
# Glue role: scoped to the three data lake buckets only (least privilege)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.project_name}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_s3_scoped" {
  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.raw.arn}/*",
      "${aws_s3_bucket.processed.arn}/*",
      "${aws_s3_bucket.curated.arn}/*",
    ]
  }
  statement {
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.raw.arn,
      aws_s3_bucket.processed.arn,
      aws_s3_bucket.curated.arn,
    ]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.data.arn]
  }
}

resource "aws_iam_policy" "glue_s3_scoped" {
  name   = "${var.project_name}-glue-s3-scoped"
  policy = data.aws_iam_policy_document.glue_s3_scoped.json
}

resource "aws_iam_role_policy_attachment" "glue_s3_scoped" {
  role       = aws_iam_role.glue.name
  policy_arn = aws_iam_policy.glue_s3_scoped.arn
}

# ---------------------------------------------------------------------------
# Firehose role: write to the raw bucket only
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.project_name}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

data "aws_iam_policy_document" "firehose_scoped" {
  statement {
    actions = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject",
    "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"]
    resources = [aws_s3_bucket.raw.arn, "${aws_s3_bucket.raw.arn}/*"]
  }
  statement {
    actions = ["kinesis:DescribeStream", "kinesis:GetShardIterator",
    "kinesis:GetRecords", "kinesis:ListShards"]
    resources = [aws_kinesis_stream.orders.arn]
  }
  statement {
    actions   = ["logs:PutLogEvents", "logs:CreateLogStream"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "firehose_scoped" {
  name   = "${var.project_name}-firehose-scoped"
  policy = data.aws_iam_policy_document.firehose_scoped.json
}

resource "aws_iam_role_policy_attachment" "firehose_scoped" {
  role       = aws_iam_role.firehose.name
  policy_arn = aws_iam_policy.firehose_scoped.arn
}

# ---------------------------------------------------------------------------
# Redshift role: MUST be trusted by redshift.amazonaws.com, NOT glue.
# The COPY command assumes this role to read Parquet from the curated bucket.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "redshift_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com", "redshift-serverless.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift" {
  name               = "${var.project_name}-redshift-role"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume.json
}

data "aws_iam_policy_document" "redshift_s3_read" {
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.curated.arn, "${aws_s3_bucket.curated.arn}/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
  }
  statement {
    actions   = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:GetPartitions"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "redshift_s3_read" {
  name   = "${var.project_name}-redshift-s3-read"
  policy = data.aws_iam_policy_document.redshift_s3_read.json
}

resource "aws_iam_role_policy_attachment" "redshift_s3_read" {
  role       = aws_iam_role.redshift.name
  policy_arn = aws_iam_policy.redshift_s3_read.arn
}

# ---------------------------------------------------------------------------
# Jenkins EC2 instance profile: push to ECR, deploy to ECS
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.project_name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "jenkins_cicd" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.backend.arn, aws_ecr_repository.frontend.arn]
  }
  statement {
    actions   = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_task_execution.arn, aws_iam_role.ecs_task.arn]
  }
}

resource "aws_iam_policy" "jenkins_cicd" {
  name   = "${var.project_name}-jenkins-cicd"
  policy = data.aws_iam_policy_document.jenkins_cicd.json
}

resource "aws_iam_role_policy_attachment" "jenkins_cicd" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins_cicd.arn
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}
