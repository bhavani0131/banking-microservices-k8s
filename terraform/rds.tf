# ---------------------------------------------------------------------------
# Standard Single-Instance RDS PostgreSQL (Free Tier Compliant)
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

resource "aws_security_group" "users_db" {
  name        = "${var.project_name}-${var.environment}-users-db-sg"
  description = "Allow PostgreSQL (5432) inside VPC"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "users" {
  identifier             = "${var.project_name}-${var.environment}-users-db"
  allocated_storage      = 20
  max_allocated_storage  = 20
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  db_name                = "veerabank_users"
  username               = "veerabank_admin"
  password               = random_password.db_master.result
  db_subnet_group_name   = aws_db_subnet_group.users.name
  vpc_security_group_ids = [aws_security_group.users_db.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
}

# Credentials handed to S3
resource "aws_s3_bucket" "users_db_creds" {
  bucket = "${var.project_name}-${var.environment}-users-db-creds-${data.aws_caller_identity.current.account_id}"
}

locals {
  users_db_creds_key = "users-db-credentials.json"
}

resource "aws_s3_object" "users_db_creds" {
  bucket       = aws_s3_bucket.users_db_creds.id
  key          = local.users_db_creds_key
  content_type = "application/json"
  content = jsonencode({
    username    = aws_db_instance.users.username
    password    = random_password.db_master.result
    host        = aws_db_instance.users.address
    reader_host = aws_db_instance.users.address
    port        = 5432
    dbname      = aws_db_instance.users.db_name
  })
}

resource "aws_iam_policy" "users_db_secret_access" {
  name        = "${var.project_name}-${var.environment}-users-db-creds-access"
  description = "Allows the users-db-sync Lambda to read the RDS credentials object from S3"

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