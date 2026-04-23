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
  }

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

variable "alb_chart_version" {
  type    = string
  default = "1.8.1"
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
  tags                 = merge(local.common_tags, { Name = "ecommerce-vpc" })
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
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# =====================
# RDS security group (EKS -> RDS:3306)
# =====================
resource "aws_security_group" "rds" {
  name        = "ecommerce-rds-sg"
  description = "RDS access from EKS"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "ecommerce-rds-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# =====================
# ECR
# =====================
resource "aws_ecr_repository" "backend" {
  name                 = var.backend_repo
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

# =====================
# Secrets Manager (existing)
# =====================
data "aws_secretsmanager_secret" "app" {
  name = var.app_secret_name
}

# =====================
# EKS cluster IAM role + cluster
# =====================
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  lifecycle {
    ignore_changes = [thumbprint_list]
  }
}

# =====================
# Node group IAM role + node group
# =====================
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_elb" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

resource "aws_eks_node_group" "backend" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "backend-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_elb,
  ]
}

# =====================
# Core EKS add-ons
# =====================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.backend]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.backend]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.backend]
}

# Container Insights - publishes pod CPU / memory / network metrics
# to CloudWatch under the ContainerInsights namespace.
resource "aws_iam_role_policy_attachment" "node_cw_agent" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "cw_observability" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on = [
    aws_eks_node_group.backend,
    aws_iam_role_policy_attachment.node_cw_agent,
  ]
}

# =====================
# AWS Load Balancer Controller
# =====================
resource "aws_iam_policy" "alb_controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "Permissions for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/alb-controller-policy.json")

  lifecycle {
    ignore_changes = [policy]
  }
}

locals {
  oidc_provider_url = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "AWSLoadBalancerControllerRole"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }
  depends_on = [aws_eks_node_group.backend]
}

resource "helm_release" "alb_controller" {
  name            = "aws-load-balancer-controller"
  repository      = "https://aws.github.io/eks-charts"
  chart           = "aws-load-balancer-controller"
  namespace       = "kube-system"
  version         = var.alb_chart_version
  wait            = true
  timeout         = 600
  replace         = true
  force_update    = true
  cleanup_on_fail = true

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.this.id
  }

  depends_on = [
    kubernetes_service_account.alb_controller,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.coredns,
    aws_eks_addon.kube_proxy,
  ]
}

# =====================
# External Secrets Operator
# =====================
resource "aws_iam_policy" "eso" {
  name        = "ExternalSecretsPolicy"
  description = "Permissions for External Secrets Operator"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds",
        "secretsmanager:ListSecrets",
      ]
      Resource = "*"
    }]
  })

  lifecycle {
    ignore_changes = [policy]
  }
}

data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "ExternalSecretsRole"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

resource "kubernetes_namespace" "eso" {
  metadata {
    name = "external-secrets"
  }
  depends_on = [aws_eks_node_group.backend]
}

resource "helm_release" "eso" {
  name            = "external-secrets"
  repository      = "https://charts.external-secrets.io"
  chart           = "external-secrets"
  namespace       = kubernetes_namespace.eso.metadata[0].name
  version         = var.eso_chart_version
  wait            = true
  timeout         = 600
  replace         = true
  force_update    = true
  cleanup_on_fail = true
}

resource "kubernetes_service_account" "eso" {
  metadata {
    name      = "external-secrets-sa"
    namespace = kubernetes_namespace.eso.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.eso.arn
    }
  }
  depends_on = [helm_release.eso]
}

# =====================
# CRD-dependent manifests, applied via raw helm chart
# (avoids the kubernetes_manifest plan-time CRD lookup that
# would otherwise force a -target two-phase apply)
# =====================
resource "helm_release" "platform_manifests" {
  name            = "platform-manifests"
  repository      = "https://bedag.github.io/helm-charts/"
  chart           = "raw"
  version         = "2.0.0"
  namespace       = "default"
  wait            = true
  timeout         = 300
  replace         = true
  force_update    = true
  cleanup_on_fail = true

  values = [yamlencode({
    resources = [
      {
        apiVersion = "external-secrets.io/v1"
        kind       = "ClusterSecretStore"
        metadata = {
          name = "aws-secrets-manager"
        }
        spec = {
          provider = {
            aws = {
              service = "SecretsManager"
              region  = var.aws_region
              auth = {
                jwt = {
                  serviceAccountRef = {
                    name      = "external-secrets-sa"
                    namespace = "external-secrets"
                  }
                }
              }
            }
          }
        }
      },
      {
        apiVersion = "external-secrets.io/v1"
        kind       = "ExternalSecret"
        metadata = {
          name      = "backend-secrets"
          namespace = "default"
        }
        spec = {
          refreshInterval = "1h0m0s"
          secretStoreRef = {
            name = "aws-secrets-manager"
            kind = "ClusterSecretStore"
          }
          target = {
            name           = "backend-secrets"
            creationPolicy = "Owner"
          }
          data = [
            { secretKey = "DB_USER", remoteRef = { key = var.rds_secret_name, property = "username" } },
            { secretKey = "DB_PASSWORD", remoteRef = { key = var.rds_secret_name, property = "password" } },
            { secretKey = "JWT_SECRET_KEY", remoteRef = { key = var.app_secret_name, property = "JWT_SECRET_KEY" } },
            { secretKey = "SECRET_KEY", remoteRef = { key = var.app_secret_name, property = "SECRET_KEY" } },
          ]
        }
      },
    ]
  })]

  depends_on = [
    helm_release.eso,
    kubernetes_service_account.eso,
  ]
}

# =====================
# Backend K8s resources
# =====================
locals {
  backend_image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.backend_repo}:${var.image_tag}"
}

resource "kubernetes_deployment_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = "default"
    labels    = { app = "backend" }
  }

  wait_for_rollout = false

  spec {
    replicas = 1
    selector {
      match_labels = { app = "backend" }
    }
    template {
      metadata {
        labels = { app = "backend" }
      }
      spec {
        container {
          name  = "backend"
          image = local.backend_image

          port {
            container_port = 5000
          }

          env {
            name  = "DB_HOST"
            value = var.rds_endpoint
          }
          env {
            name  = "DB_NAME"
            value = "ecommerce_db"
          }
          env {
            name  = "FLASK_ENV"
            value = "production"
          }
          env {
            name  = "CORS_ORIGINS"
            value = var.frontend_url
          }
          env {
            name = "DB_USER"
            value_from {
              secret_key_ref {
                name = "backend-secrets"
                key  = "DB_USER"
              }
            }
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "backend-secrets"
                key  = "DB_PASSWORD"
              }
            }
          }
          env {
            name = "JWT_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "backend-secrets"
                key  = "JWT_SECRET_KEY"
              }
            }
          }
          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "backend-secrets"
                key  = "SECRET_KEY"
              }
            }
          }

          resources {
            requests = {
              cpu    = "256m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.platform_manifests]
}

resource "kubernetes_service_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = "default"
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "backend" }
    port {
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = "default"
    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/subnets"          = "${aws_subnet.public_a.id},${aws_subnet.public_b.id}"
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/health"
    }
  }

  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.backend.metadata[0].name
              port {
                number = 5000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.alb_controller]
}

# =====================
# Outputs
# =====================
output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_a_id" {
  value = aws_subnet.public_a.id
}

output "subnet_b_id" {
  value = aws_subnet.public_b.id
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "ecr_backend_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "backend_alb_hostname" {
  value       = try(kubernetes_ingress_v1.backend.status[0].load_balancer[0].ingress[0].hostname, "")
  description = "Backend ALB DNS - takes ~3-5 min to populate after first apply"
}

# =====================
# CloudWatch dashboard - backend
# =====================
data "aws_lb" "backend" {
  tags = {
    "ingress.k8s.aws/stack" = "default/backend"
  }
  depends_on = [kubernetes_ingress_v1.backend]
}

resource "aws_cloudwatch_dashboard" "backend" {
  dashboard_name = "ecommerce-backend"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Backend ALB - request count & 5xx",
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",            "LoadBalancer", data.aws_lb.backend.arn_suffix],
            [".",                  "HTTPCode_Target_5XX_Count", ".",          "."],
            [".",                  "HTTPCode_ELB_5XX_Count",    ".",          "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Backend ALB - response time & healthy hosts"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", data.aws_lb.backend.arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "HealthyHostCount",   "LoadBalancer", data.aws_lb.backend.arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", data.aws_lb.backend.arn_suffix, { stat = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Backend pods - CPU utilization (%)"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["ContainerInsights", "pod_cpu_utilization", "ClusterName", aws_eks_cluster.this.name, "Namespace", "default", "Service", "backend"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Backend pods - memory utilization (%)"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["ContainerInsights", "pod_memory_utilization", "ClusterName", aws_eks_cluster.this.name, "Namespace", "default", "Service", "backend"]
          ]
        }
      }
    ]
  })
}

output "backend_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=ecommerce-backend"
}
