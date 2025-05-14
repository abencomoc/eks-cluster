terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.47"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.10"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.4"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.3"
    }
  }
}

provider "aws" {
  region = local.region
}

# provider "helm" {
#   kubernetes {
#     host                   = module.eks.cluster_endpoint
#     cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     # This requires the awscli to be installed locally where Terraform is executed
#     args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
#             "--region", local.region]
#   }
#   }
# }

# provider "kubectl" {
#   apply_retry_count      = 30
#   host                   = module.eks.cluster_endpoint
#   cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
#   load_config_file       = false

#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     # This requires the awscli to be installed locally where Terraform is executed
#     args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
#             "--region", local.region]
#   }
# }

data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name   = "${basename(path.cwd)}-${random_string.suffix.result}"
  region = "us-east-1"

  cluster_version = "1.31"

  vpc_cidr = "10.0.0.0/16"
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Blueprint  = local.name
  }

}

# Add a random string resource
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper = false
}

###############################################################
# EKS Cluster
###############################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = local.name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access = true

  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # # Enable EKS AutoMode
  # cluster_compute_config = {
  #   enabled    = true
  #   node_pools = []
  # }

  eks_managed_node_groups = {
    group1 = {
      min_size     = 2
      max_size     = 3
      desired_size = 2
      instance_types = ["t3.medium"]
    }
    group2 = {
      min_size     = 1
      max_size     = 2
      desired_size = 1
      instance_types = ["t3.medium"]
      tags = {
        purpose = "test"
      }
    }
  }

  tags = local.tags
}

resource "aws_autoscaling_group_tag" "specific" {
  autoscaling_group_name = module.eks.eks_managed_node_groups_autoscaling_group_names[0]

  tag {
    key                 = "k8s.io/cluster-autoscaler/node-template/autoscaling-options/scaledownunneededtime"
    value               = "10m"
    propagate_at_launch = false
  }
}

###############################################################
# Supporting Resources
###############################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = local.name
  cidr = local.vpc_cidr

  azs  = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  tags = local.tags
}


###############################################################
# Outputs
###############################################################

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}