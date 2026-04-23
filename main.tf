terraform {
required_version = ">= 1.6.0"

required_providers {
aws = {
source  = "hashicorp/aws"
version = "~> 5.60"
}
}

backend "s3" {}
}

provider "aws" {
region = var.aws_region
}

# -------------------------

# Variables

# -------------------------

variable "aws_region" {
default = "us-east-1"
}

variable "cluster_name" {
default = "ecommerce-cluster"
}

variable "image_tag" {
default = "latest"
}

# -------------------------

# VPC

# -------------------------

resource "aws_vpc" "main" {
cidr_block = "10.0.0.0/16"

tags = {
Name = "ecommerce-vpc"
}
}

resource "aws_subnet" "a" {
vpc_id     = aws_vpc.main.id
cidr_block = "10.0.1.0/24"
availability_zone = "us-east-1a"
}

resource "aws_subnet" "b" {
vpc_id     = aws_vpc.main.id
cidr_block = "10.0.2.0/24"
availability_zone = "us-east-1b"
}

# -------------------------

# ECR

# -------------------------

resource "aws_ecr_repository" "repo" {
name = "backend-repo"
}

# -------------------------

# IAM Role

# -------------------------

resource "aws_iam_role" "eks_role" {
name = "eks-role"

assume_role_policy = jsonencode({
Version = "2012-10-17"
Statement = [{
Effect = "Allow"
Principal = { Service = "eks.amazonaws.com" }
Action = "sts:AssumeRole"
}]
})
}

resource "aws_iam_role_policy_attachment" "eks_attach" {
role       = aws_iam_role.eks_role.name
policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -------------------------

# EKS Cluster

# -------------------------

resource "aws_eks_cluster" "eks" {
name     = var.cluster_name
role_arn = aws_iam_role.eks_role.arn

vpc_config {
subnet_ids = [
aws_subnet.a.id,
aws_subnet.b.id
]
}

depends_on = [
aws_iam_role_policy_attachment.eks_attach
]
}
