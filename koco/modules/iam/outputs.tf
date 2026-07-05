output "eks_node_group_role_arn" {
    description = "EKS node group IAM 역할 ARN"
    value = aws_iam_role.node_group_role.arn
}
output "ebs_csi_irsa_role_arn" {
  value = aws_iam_role.ebs_csi_irsa_role.arn
}
output "alb_ingress_sa_role_arn" {
  value = aws_iam_role.alb_ingress_sa_role.arn
}