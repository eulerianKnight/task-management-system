# terraform/main.tf
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
  }

  # backend "s3" {
  #   bucket = "task-management-files"
  #   key    = "task-management/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

# Get authentication data for the EKS cluster
# This data source uses the aws provider to get a token for the kubernetes provider
data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}
# Configure the Kubernetes provider to connect to the new EKS cluster
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# Configure the Helm provider as well (good practice)
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "aws" {
  region = var.aws_region
}

# Get current AWS account and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}