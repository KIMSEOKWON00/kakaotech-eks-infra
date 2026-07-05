terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
  }
}

# ALB용 ACM 인증서 발급 및 검증 (서울 리전)
data "aws_route53_zone" "main" {
  name         = var.domain_name 
  private_zone = false
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"

  set {
    name  = "clusterName"
    value = var.cluster_name 
  } 
  
  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
}

resource "helm_release" "argocd" {

  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.6"

  create_namespace = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
  name  = "server.extraArgs[0]"
  value = "--insecure"
}

  set {
    name  = "configs.params.server.insecure"
    value = "true"
  }
}

resource "kubernetes_ingress_v1" "argocd_ingress" {

  depends_on = [helm_release.argocd]
  
  metadata {
    name      = "argocd-ingress"
    namespace = "argocd"
    annotations = {
      "kubernetes.io/ingress.class"                = "alb"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/group.name"       = "koco-alb-group"
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\": 443}]"
      "alb.ingress.kubernetes.io/certificate-arn"  = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
    }
  }

  spec {
    rule {
      host = "argocd.${var.domain_name}"
      http {
        path {
          path     = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# ALB 검색
data "aws_lbs" "argocd_albs" {
  tags = {
    "elbv2.k8s.aws/cluster"       = var.cluster_name
    "ingress.k8s.aws/resource"    = "LoadBalancer"
    "ingress.k8s.aws/stack"       = "koco-alb-group"
  }

  depends_on = [ kubernetes_ingress_v1.argocd_ingress ]
}

# ALB 상세 조회
data "aws_lb" "argocd_alb" {
  arn = tolist(data.aws_lbs.argocd_albs.arns)[0]
  depends_on = [ data.aws_lbs.argocd_albs ]
}

# Route 53 - ArgoCD
resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "argocd.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.argocd_alb.dns_name
    zone_id                = data.aws_lb.argocd_alb.zone_id
    evaluate_target_health = false
  }
}

# Route 53 - kibana
resource "aws_route53_record" "kibana" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "kibana.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.argocd_alb.dns_name
    zone_id                = data.aws_lb.argocd_alb.zone_id
    evaluate_target_health = false
  }
}

# Route 53
resource "aws_route53_record" "api_root" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"         
  type    = "A"

  alias {
    name                   = data.aws_lb.argocd_alb.dns_name
    zone_id                = data.aws_lb.argocd_alb.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.argocd_alb.dns_name
    zone_id                = data.aws_lb.argocd_alb.zone_id
    evaluate_target_health = false
  }
}

# Route 53 - apm
resource "aws_route53_record" "apm" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "apm.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.argocd_alb.dns_name
    zone_id                = data.aws_lb.argocd_alb.zone_id
    evaluate_target_health = false
  }
}