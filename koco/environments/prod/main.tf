locals {
  cluster_name = "koco-prod-cluster"
  oidc_url_without_https = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}
module "koco_vpc" {
  source              = "../../modules/vpc"

  stage               = var.stage
  servicename         = var.servicename
  tags                = var.vpc_tags
  cluster_name        = local.cluster_name

  az                  = var.az
  vpc_ip_range        = var.vpc_ip_range

  subnet_public_az1   = var.subnet_public_az1
  subnet_public_az2   = var.subnet_public_az2
  subnet_service_az1  = var.subnet_service_az1
  subnet_service_az2  = var.subnet_service_az2
  subnet_db_az1       = var.subnet_db_az1
  subnet_db_az2       = var.subnet_db_az2
}

module "koco_security_group" {
  source = "../../modules/security_group"
  stage               = var.stage
  servicename         = var.servicename

  vpc_id = module.koco_vpc.vpc_id
  vpc_cidr_block = var.vpc_ip_range
  node_group_sg_id = ""
}

module "openvpn" {
    source = "../../modules/openvpn"
    
    stage               = var.stage
    servicename         = var.servicename
    tags                = var.openvpn_tags
    
    vpc_id = module.koco_vpc.vpc_id
    subnet_id = module.koco_vpc.public_az1_id
    vpc_security_group_ids = [module.koco_security_group.sg_openvpn_id]
}

module "db" {
    source = "../../modules/db_instance"

    stage               = var.stage
    servicename         = var.servicename
    tags                = var.openvpn_tags

    subnet_private_id = module.koco_vpc.db_az1_id
    security_group_db_sg_id = module.koco_security_group.sg_db_id
    ip = var.db_ip

    depends_on = [ module.koco_vpc ]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  
  version = "~>20.0"
  cluster_name    = local.cluster_name
  cluster_version = "1.32"
  #create_node_security_group = false

    cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  vpc_id                         = module.koco_vpc.vpc_id
  subnet_ids                     = [module.koco_vpc.service_az1_id, module.koco_vpc.service_az2_id]
  cluster_endpoint_public_access = true
  cluster_endpoint_private_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD" #"AL2_x86_64"
    iam_role_arn = module.iam.eks_node_group_role_arn
  }

  eks_managed_node_groups = {

    # Infra용 (ArgoCD, ELK 등)
    infra = {
      name           = "koco-prod-infra-node"
      instance_types = ["t3.medium"]
      min_size       = 4
      max_size       = 5
      desired_size   = 4
      disk_size = 30

      labels = {
        "node-group" = "infra"
      }
    }

    # App용 (Springboot)
    app = { 
      name = "koco-prod-app-node"

      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 2
      desired_size = 2
      disk_size = 3

      #   taints = [
      #     {
      #       key    = "dedicated"
      #       value  = "app"
      #       effect = "NO_SCHEDULE"
      #     }
      #   ]

      labels = {
        "node-group" = "app"
      }
    }
  }

  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = true
}

module "sa" {
    source = "../../modules/service_account"

    depends_on = [module.eks]
}

module "iam" {
  source = "../../modules/iam"

  role-alc-oidc_without_https = local.oidc_url_without_https
  role-alc-namespace = module.sa.sa-namespace
  role-alc-sa_name = module.sa.sa-name

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_url_without_https = local.oidc_url_without_https
}

module "helm" {
    source = "../../modules/helm"
    vpc_id = module.koco_vpc.vpc_id
    domain_name = var.domain_name
    acm_certificate_arn = var.acm_certificate_arn
    cluster_name = local.cluster_name

    providers = { helm = helm.eks }

    depends_on = [module.koco_vpc, module.eks, module.sa, module.iam] 
}

module "s3_static_site" {
  source              = "../../modules/s3_static_site"
  cloudfront_oai_arn  = module.cdn.cloudfront_oai_arn
  bucket_name = var.s3-static-bucket-name
}

module "cdn" {
  source         = "../../modules/cdn"
  s3_bucket_name = module.s3_static_site.s3_bucket_name
  alb_dns_name = module.helm.alb_dns
  domain_name = var.domain_name
  acm_certificate_arn = var.acm_certificate_arn
  depends_on = [ module.helm ]
}

module "ecr" {
    source = "../../modules/ecr"
    repository_name = var.repository_name
}