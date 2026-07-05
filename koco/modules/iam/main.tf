resource "aws_iam_role" "node_group_role" {
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# EBS CSI Driver 권한 추가
resource "aws_iam_role_policy_attachment" "node_AmazonEBSCSIDriverPolicy" {
  role       = aws_iam_role.node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "alb_ingress_sa_role" {
  name = var.role-alc_role_name

  # EKS Pod Identity 기반 신뢰 정책 (OIDC/IRSA 대신 사용)
  # aws_eks_pod_identity_association이 namespace/service_account ↔ role을 직접 연결하므로
  # ServiceAccount 어노테이션이나 OIDC sub 조건 문자열 매칭이 필요 없다.
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
  })
}

resource "aws_eks_pod_identity_association" "alb_ingress" {
  cluster_name    = var.cluster_name
  namespace       = var.role-alc-namespace
  service_account = var.role-alc-sa_name
  role_arn        = aws_iam_role.alb_ingress_sa_role.arn

  # ebs_csi_irsa_role는 var.oidc_provider_arn(module.eks 출력)에 의존하므로,
  # 이 리소스가 먼저 만들어진 뒤라야 EKS 클러스터가 실제로 존재함이 보장된다.
  depends_on = [aws_iam_role.ebs_csi_irsa_role]
}

resource "aws_iam_policy" "iam_policy-aws-loadbalancer-controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/iam_policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_ingress_policy_attach" {
  policy_arn = aws_iam_policy.iam_policy-aws-loadbalancer-controller.arn
  role       = aws_iam_role.alb_ingress_sa_role.name
  depends_on = [aws_iam_role.alb_ingress_sa_role, aws_iam_policy.iam_policy-aws-loadbalancer-controller]
}

# 1. EBS CSI Controller용 IAM Role (IRSA용)
resource "aws_iam_role" "ebs_csi_irsa_role" {
  name = "AmazonEKS_EBS_CSI_Driver_IRSA"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = var.oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${var.oidc_url_without_https}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

# 2. EBS CSI Policy 연결
resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy" {
  role       = aws_iam_role.ebs_csi_irsa_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}