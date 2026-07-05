data "aws_caller_identity" "current" {}

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

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.role-alc-oidc_without_https}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${var.role-alc-oidc_without_https}:aud": "sts.amazonaws.com", #인증 요청 대상
                    "${var.role-alc-oidc_without_https}:sub": "system:serviceaccount:${var.role-alc-namespace}:${var.role-alc-sa_name}"
                }
            }
        }
    ]
  })
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