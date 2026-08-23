# ---------------------------------------------------------------------------
# RDS (Aurora PostgreSQL Serverless v2) - relational replica of user accounts.
# ---------------------------------------------------------------------------

resource "random_password" "db_master" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_db_subnet_group" "users" {
  name       = "${var.project_name}-${var.environment}-users-db"
  subnet_ids = local.private_subnet_ids
}

# Security group attached to the users-db-sync Lambda
resource "aws_security_group" "users_db_sync_lambda" {
  name        = "${var.project_name}-${var.environment}-users-db-sync-lambda-sg"
  description = "Attached to the users-db-sync Lambda (DynamoDB Streams to RDS)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "users_db" {
  name        = "${var.project_name}-${var.environment}-users-db-sg"
  description = "Allow PostgreSQL (5432) from the users-db-sync Lambda to the users Aurora cluster"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL from the users-db-sync Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.users_db_sync_lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_rds_cluster" "users" {
  cluster_identifier      = "${var.project_name}-${var.environment}-users-db"
  engine                  = "aurora-postgresql"
  engine_mode             = "provisioned"
  database_name           = "veerabank_users"
  master_username         = "veerabank_admin"
  master_password         = random_password.db_master.result
  db_subnet_group_name    = aws_db_subnet_group.users.name
  vpc_security_group_ids  = [aws_security_group.users_db.id]

  storage_encrypted       = true
  skip_final_snapshot     = true
  backup_retention_period = 1
}

# Writer instance
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.project_name}-${var.environment}-users-db-writer"
  cluster_identifier = aws_rds_cluster.users.id
  instance_class     = "db.t3.micro"
  engine             = aws_rds_cluster.users.engine
  promotion_tier     = 0
}

# Reader instance
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.project_name}-${var.environment}-users-db-reader"
  cluster_identifier = aws_rds_cluster.users.id
  instance_class     = "db.t3.micro"
  engine             = aws_rds_cluster.users.engine
  promotion_tier     = 1
}

# Credentials handed to the users-db-sync Lambda via a private S3 bucket
resource "aws_s3_bucket" "users_db_creds" {
  bucket = "${var.project_name}-${var.environment}-users-db-creds-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "users_db_creds" {
  bucket = aws_s3_bucket.users_db_creds.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "users_db_creds" {
  bucket = aws_s3_bucket.users_db_creds.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "users_db_creds" {
  bucket                  = aws_s3_bucket.users_db_creds.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  users_db_creds_key = "users-db-credentials.json"
}

resource "aws_s3_object" "users_db_creds" {
  bucket                 = aws_s3_bucket.users_db_creds.id
  key                    = local.users_db_creds_key
  server_side_encryption = "AES256"
  content_type           = "application/json"
  content = jsonencode({
    username    = aws_rds_cluster.users.master_username
    password    = random_password.db_master.result
    host        = aws_rds_cluster.users.endpoint
    reader_host = aws_rds_cluster.users.reader_endpoint
    port        = 5432
    dbname      = aws_rds_cluster.users.database_name
  })

  depends_on = [aws_rds_cluster_instance.writer, aws_rds_cluster_instance.reader]
}

resource "aws_iam_policy" "users_db_secret_access" {
  name        = "${var.project_name}-${var.environment}-users-db-creds-access"
  description = "Allows the users-db-sync Lambda to read the Aurora PostgreSQL credentials object from S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadUsersDbCredsObject"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.users_db_creds.arn}/${local.users_db_creds_key}"
      },
      {
        Sid      = "ListUsersDbCredsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.users_db_creds.arn
      }
    ]
  })
}