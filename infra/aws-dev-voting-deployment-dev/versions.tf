terraform {
  required_version = ">= 1.5.0"
  # No S3 backend configured — state is local. Set a Terraform state
  # bucket on the Infrastructure page for production use.
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    # Used to pull the upstream AWS Load Balancer Controller IAM policy at
    # apply time so it can never go stale — see aws_iam_policy.alb_controller.
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Auth against the freshly-created EKS cluster via the aws exec plugin so
# that both kubernetes and helm providers can install add-ons in the SAME
# terraform apply. Without exec-plugin auth we'd need a stored kubeconfig,
# which doesn't exist yet on first apply — chicken-and-egg.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
