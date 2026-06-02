variable "aws_region" {
  description = "The AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project used for resource naming and tagging"
  type        = string
  default     = "cloud-signup"
}

variable "environment" {
  description = "The deployment environment"
  type        = string
  default     = "prod"
}