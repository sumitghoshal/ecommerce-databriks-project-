variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name used in tags"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Prefix for all resource names"
  type        = string
  default     = "ecommerce-devops"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "bucket_suffix" {
  description = "Unique suffix for S3 bucket names (S3 names are globally unique). Use your initials or account id."
  type        = string
}

variable "redshift_admin_password" {
  description = "Redshift admin password. Pass via -var or TF_VAR_redshift_admin_password; never commit it."
  type        = string
  sensitive   = true
}

variable "mongo_uri" {
  description = "MongoDB connection string stored in Secrets Manager and injected into the backend task."
  type        = string
  sensitive   = true
}

variable "alert_email" {
  description = "Email address subscribed to the SNS alerts topic. You must confirm the subscription email."
  type        = string
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.4/32) for Jenkins SSH/UI access."
  type        = string
}

variable "backend_desired_count" {
  description = "Number of backend tasks"
  type        = number
  default     = 2
}

variable "frontend_desired_count" {
  description = "Number of frontend tasks"
  type        = number
  default     = 2
}
