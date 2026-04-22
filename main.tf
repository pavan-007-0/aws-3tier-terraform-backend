terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # Bucket name is supplied by the pipeline via:
  #   terraform init -backend-config="bucket=$STATE_BUCKET"
  backend "s3" {
    key    = "ecommerce/backend/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# =====================
# Variables
# =====================
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "ecommerce-cluster"
}

variable "eks_version" {
  type    = string
  default = "1.32"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_a_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "subnet_b_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_min" {
  type    = number
  default = 1
}

variable "node_max" {
  type    = number
  default = 3
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "backend_repo" {
  type    = string
  default = "backend-repo"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "rds_endpoint" {
  type    = string
  default = "database-1.coxucmkk0rho.us-east-1.rds.amazonaws.com"
}

variable "rds_secret_name" {
  type    = string
  default = "rds!db-a31a37c1-ddb2-4685-a5c6-dbd11475e1ab"
}

variable "app_secret_name" {
  type    = string
  default = "secrets/backend/app"
}

variable "eso_chart_version" {
  type    = string
  default = "0.20.4"
}

variable "frontend_url" {
  type    = string
  default = "http://localhost:4200"
}

# =====================
# Data + locals
# =====================
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    Name      = "ecommerce"
    ManagedBy = "terraform"
  }
}

# =====================
# VPC / networking
# =====================
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "ecommerce-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "ecommerce-igw" })
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_a_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                        = "ecommerce-subnet-public-a"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_b_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                        = "ecommerce-subnet-public-b"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, { Name = "ecommerce-public-rt" })
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id