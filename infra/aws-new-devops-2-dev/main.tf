locals {
  cluster_name = "aws-new-devops-2-dev"
  region       = "us-east-1"

  # AWS Load Balancer Controller version pair — KEEP THESE IN SYNC.
  #   alb_chart_version : the Helm chart (helm_release.aws_lb_controller)
  #   alb_policy_ref    : the controller git tag whose docs/install/iam_policy.json
  #                       we attach to the controller's IRSA role
  # Chart 1.8.x ships controller v2.8.x. Bumping one without the other risks a
  # controller that needs a permission its policy doesn't grant (that is the
  # 403 AccessDenied / DescribeListenerAttributes failure we hit in 2026-07).
  alb_chart_version = "1.8.1"
  alb_policy_ref    = "v2.8.1"

  tags = {
    ManagedBy   = "DeepAgent"
    Cluster     = local.cluster_name
    Environment = "production"
    Team        = "devops"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  vpc_cidr = "10.30.0.0/16"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  # One AZ per subnet pair. Capped at what the region actually offers, so a
  # 3-subnet request in a 2-AZ region degrades instead of failing the apply.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(3, length(data.aws_availability_zones.available.names)),
  )

  # Carved out of local.vpc_cidr rather than hardcoded, so changing the VPC
  # range moves every subnet with it. /16 + newbits 8 = /24 per subnet.
  private_subnets = [for i in range(3) : cidrsubnet(local.vpc_cidr, 8, i + 1)]
  public_subnets  = [for i in range(3) : cidrsubnet(local.vpc_cidr, 8, i + 101)]

  # The module creates the internet gateway, NAT gateway(s), route tables and
  # their associations: public subnets route 0.0.0.0/0 to the IGW, private
  # subnets route it to the NAT.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Subnet tags Kubernetes uses to place load balancers. Without role/elb on
  # the public subnets, a Service type=LoadBalancer hangs at EXTERNAL-IP
  # <pending> because cloud-controller-manager can't find a subnet to use.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.tags
}

locals {
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = concat(module.vpc.private_subnets, module.vpc.public_subnets)
  node_subnet_ids = module.vpc.private_subnets
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.33"

  # Required for the AWS Load Balancer Controller (and EBS CSI IRSA) to bind
  # IAM roles to Kubernetes service accounts via the cluster's OIDC issuer.
  enable_irsa = true

  # STANDARD support, explicitly. A cluster left on EXTENDED support keeps
  # running past its Kubernetes version's standard-support window — and AWS
  # charges roughly 6x the control-plane rate for the privilege (~$0.60/hr vs
  # ~$0.10/hr). That is a silent ~$365/month per cluster for a setting nobody
  # chose. STANDARD means the cluster must be upgraded before end-of-support,
  # which is the behaviour you want by default; opt into EXTENDED deliberately.
  cluster_upgrade_policy = {
    support_type = "STANDARD"
  }

  # API-only auth. Access is granted purely through EKS Access Entries (see
  # access_entries below), not the legacy aws-auth ConfigMap. Keeping the
  # ConfigMap path alive means two sources of truth for cluster access, and
  # editing it by hand is the classic way to lock everyone out of a cluster.
  authentication_mode = "API"

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  # Control-plane logging → CloudWatch (api, audit, authenticator, controllerManager, scheduler).
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Encrypt Kubernetes secrets at rest with a dedicated KMS key (module-managed).
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }

    # metrics-server — without it `kubectl top` returns "Metrics API not
    # available" and every HorizontalPodAutoscaler sits at <unknown>/80% and
    # never scales. Not installed by default by EKS, and its absence is only
    # discovered the first time someone tries to autoscale.
    metrics-server = { most_recent = true }

    # eks-pod-identity-agent — the modern successor to IRSA for granting pods
    # AWS permissions. Harmless when unused; required the moment anyone adds a
    # Pod Identity association, and the console warns about its absence.
    eks-pod-identity-agent = { most_recent = true }
    # EBS CSI driver — MUST have an IRSA-bound service account role,
    # otherwise the controller pods can't call EC2 APIs (CreateVolume,
    # CreateSnapshot, etc.) and the addon hangs at "CREATING" until
    # timeout. See module.ebs_csi_irsa below.
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  vpc_id     = local.vpc_id
  subnet_ids = local.subnet_ids

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    aws-new-devops-2-dev-workers = {
      subnet_ids     = local.node_subnet_ids
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      disk_size      = 100
      labels = { role = "workers" }
    }
  }

  tags = local.tags
}

# ────────────────────────────────────────────────────────────────────────
# EBS CSI driver IRSA role — required for the aws-ebs-csi-driver addon
# to function. Without a role bound to the ebs-csi-controller-sa service
# account, the addon deploys but hangs at CREATING (controller pods can't
# call EC2). The community iam-role-for-service-accounts-eks module
# packages the exact IAM policy + trust the CSI driver needs.
# ────────────────────────────────────────────────────────────────────────
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${local.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# ════════════════════════════════════════════════════════════════════════
# AWS Load Balancer Controller — Terraform-MANAGED, not a manual step.
# ════════════════════════════════════════════════════════════════════════
# WHAT IT DOES: reconciles Kubernetes Ingress objects into ALBs (Layer 7)
# and annotated Services into NLBs (Layer 4).
#
# WHY IT IS DECLARED HERE (2026-07 incident):
#   * It was previously installed by hand via `eksctl create iamserviceaccount`
#     + `helm install`. That does NOT survive a cluster rebuild, cannot be
#     reproduced by a teammate, and drifts silently. Any cluster this module
#     builds now gets the controller in the same `terraform apply`.
#   * Our standard exposure pattern is Service type=ClusterIP + Ingress
#     (ingressClassName=alb) — see the ADR in lib/devops/deploy-manifest.ts.
#     Without this controller, those Ingress objects have nothing to
#     reconcile them and no ALB is ever created.
#   * Private-subnet clusters have NO working alternative: the in-tree
#     cloud-controller-manager only makes Classic ELBs, which cannot attach
#     to private subnets. The Service just hangs at EXTERNAL-IP <pending>
#     with no surfaced error.
#
# Subnet discovery is tag-driven (public: kubernetes.io/role/elb=1, private:
# kubernetes.io/role/internal-elb=1). Both the new-VPC and reuse-existing-VPC
# paths in this file apply those tags.
# ────────────────────────────────────────────────────────────────────────
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.cluster_name}-alb-controller"

  # NOTE: `attach_load_balancer_controller_policy = true` is deliberately NOT
  # used. That flag attaches a policy SNAPSHOT vendored inside the IAM module,
  # which goes stale as the controller adds permissions in new releases. It is
  # precisely how we shipped a controller role missing
  # elasticloadbalancing:DescribeListenerAttributes, so ALB provisioning failed
  # with 403 AccessDenied *after* we had already switched to Ingress/ALB.
  # We attach the upstream policy instead — see aws_iam_policy.alb_controller.

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

# Upstream AWSLoadBalancerControllerIAMPolicy, fetched at apply time so it can
# never be stale. Pinned to the controller tag that MATCHES the Helm chart we
# install (see local.alb_chart_version / local.alb_policy_ref) so the granted
# permissions and the running controller are always version-consistent —
# tracking `main` instead would work too, but makes a re-apply of an old
# commit non-reproducible. Bump both locals together when upgrading.
data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${local.alb_policy_ref}/docs/install/iam_policy.json"

  request_headers = {
    Accept = "application/json"
  }
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${local.cluster_name}-alb-controller"
  description = "Upstream AWSLoadBalancerControllerIAMPolicy @ ${local.alb_policy_ref} (fetched, not vendored — see comments)"
  policy      = data.http.alb_controller_policy.response_body

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = module.lb_controller_irsa.iam_role_name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# The ServiceAccount must exist BEFORE the helm chart deploys — the chart
# is configured with serviceAccount.create=false so it expects one already
# annotated with the IRSA role ARN.
resource "kubernetes_service_account" "aws_lb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.lb_controller_irsa.iam_role_arn
    }
    labels = {
      "app.kubernetes.io/name"       = "aws-load-balancer-controller"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.alb_chart_version # pinned; paired with local.alb_policy_ref

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_lb_controller.metadata[0].name
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = local.vpc_id
  }

  # Depend on BOTH the ServiceAccount (helm expects it to already exist,
  # serviceAccount.create=false) AND the policy attachment — a controller that
  # starts before its IAM permissions land logs 403s and needs a restart.
  depends_on = [
    kubernetes_service_account.aws_lb_controller,
    aws_iam_role_policy_attachment.alb_controller,
  ]
}
