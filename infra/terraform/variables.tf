variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for AWS resources."
  type        = string
  default     = "alchemyst-devops"
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to the public gateway. Use your_ip/32."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR."
  type        = string
  default     = "10.40.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR."
  type        = string
  default     = "10.40.10.0/24"
}

variable "gateway_instance_type" {
  description = "Gateway EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "engine_instance_type" {
  description = "iii engine EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "caller_instance_type" {
  description = "TypeScript caller worker EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "inference_instance_type" {
  description = "Python inference worker EC2 instance type. Model load likely needs more RAM than t3.micro."
  type        = string
  default     = "t3.large"
}
