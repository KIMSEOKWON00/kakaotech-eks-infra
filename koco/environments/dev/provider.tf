terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13.0"

    }
  }

  # 백엔드 설정: 원격 상태 저장소를 사용하는 경우 설정
  backend "s3" {                                # Terraform 상태 파일(terraform.tfstate)을 S3에 저장하도록 설정
    bucket = "koco-terraformstate"              # 버킷 이름
    key  = "./terraform.tfstate"                # dev 환경의 상태파일을 이 경로에 저장하겠다는 의미
    region = "ap-northeast-2"                   # 버킷이 존재하는 region
    encrypt = true                              # S3 버킷에 저장되는 상태 파일을 자동으로 암호화
    dynamodb_table = "koco-terraformstate"      # DynamoDB 테이블을 통해 동시 작업 잠금 기능을 활성화하여 작업 중 충돌을 방지
  }
}

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  alias = "eks"

  kubernetes = {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}