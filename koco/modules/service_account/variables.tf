variable "sa-name"{
  type = string
  default = "aws-load-balancer-controller"
}

variable "sa-namespace"{
  type = string
  default = "kube-system"
}

variable "sa-annotations" {
  # EKS Pod Identity 사용 시 IAM Role 연결은 aws_eks_pod_identity_association이
  # namespace/service_account 기준으로 직접 담당하므로 별도 어노테이션이 필요 없다.
  type = map(string)
  default = {}
}
