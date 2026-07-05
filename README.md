```
██╗  ██╗ ██████╗  ██████╗ ██████╗
██║ ██╔╝██╔═══██╗██╔════╝██╔═══██╗
█████╔╝ ██║   ██║██║     ██║   ██║
██╔═██╗ ██║   ██║██║     ██║   ██║
██║  ██╗╚██████╔╝╚██████╗╚██████╔╝
╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═════╝
Terraform × EKS × GitOps Infrastructure
```

## 한 줄 소개

**Terraform으로 AWS EKS 클러스터와 주변 인프라(VPC, IAM, ALB, CloudFront, ECR 등)를 코드화하고, ArgoCD 기반 GitOps로 애플리케이션 배포를 자동화한 인프라 프로젝트**입니다. IAM 인증 체계를 OIDC/IRSA에서 **EKS Pod Identity**로 전환했고, 인프라(Terraform 리포)와 애플리케이션(GitOps 리포)의 책임 경계를 명확히 분리해 설계했습니다.

---

## 목차

1. [전체 인프라 아키텍처](#전체-인프라-아키텍처)
2. [사용 AWS 서비스 및 도구](#사용-aws-서비스-및-도구)
3. [Terraform 모듈 구조](#terraform-모듈-구조)
4. [EKS 클러스터 구성](#eks-클러스터-구성)
5. [Helm 배포 구성](#helm-배포-구성)
6. [IAM 및 IRSA 설계](#iam-및-irsa-설계)
7. [네트워크 설계](#네트워크-설계)
8. [스토리지 / CDN / 이미지 레지스트리](#스토리지--cdn--이미지-레지스트리)
9. [실행 방법](#실행-방법)
10. [연관 프로젝트](#연관-프로젝트)

---

## 전체 인프라 아키텍처

트래픽이 실제로 흐르는 경로와, 코드가 배포되는 경로(GitOps)는 서로 다른 흐름이라 두 다이어그램으로 나눠서 표현했습니다.

### 트래픽 흐름

```
Internet
   │
   ▼
CloudFront ── (S3 오리진: 프론트엔드 정적 파일)
   │
   ▼ (/api, /oauth)
ALB (koco-alb-group, 4개 서브도메인 공유)
   │
   ▼
┌──────────────────────── EKS Cluster (v1.32) ────────────────────────────┐
│                                                                         │
│  infra 노드그룹 (t3.medium × 4~5)       app 노드그룹 (t3.medium × 1~2)      │
│  ├── ArgoCD (argo-cd 5.51.6)           └── Spring Boot                  │
│  ├── Elasticsearch / Kibana                                             │
│  ├── Filebeat / Metricbeat / APM Server                                 │
│  └── Redis                                                              │
│                                                                         │
│  ALB Controller (aws-load-balancer-controller 1.7.1, EKS Pod Identity)  │
└─────────────────────────────────────────────────────────────────────────┘

(EKS 클러스터 밖, Terraform이 별도 프로비저닝)
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│ EC2 MySQL     │   │ ECR           │   │ OpenVPN EC2   │
│ (db_instance) │   │ (이미지 저장)    │   │ (관리자 접근)    │
└───────────────┘   └───────────────┘   └───────────────┘
```

### 배포 흐름 (GitOps)

```
Developer
   │ git push
   ▼
GitOps Repository (kakaotech-21-iceT-gitops)
   │ ArgoCD 감지 및 동기화 (App of Apps, syncWave 순서)
   ▼
ArgoCD (EKS 내부)
   ├── Wave -1: EBS CSI Driver
   ├── Wave  0: StorageClass, metrics-server
   ├── Wave  1: Elasticsearch, Redis
   └── Wave 2~4: Kibana, APM, Filebeat, Spring
```

**설계 의도**
- ALB를 서비스별로 각각 만들지 않고 `koco-alb-group` 하나로 묶어 ArgoCD/Kibana/APM/API 4개 서브도메인이 공유하도록 했습니다. ALB 개수를 줄여 비용과 운영 포인트를 최소화하는 선택입니다.
- EKS 노드그룹을 `infra`(상시 구동 인프라 워크로드)와 `app`(비즈니스 로직)으로 분리해, 워크로드 성격에 따라 스케일링 범위와 인스턴스 수를 독립적으로 조정할 수 있게 했습니다.
- 인프라 프로비저닝(Terraform)과 워크로드 배포(GitOps/ArgoCD)를 서로 다른 리포로 분리해, 애플리케이션 배포 하나 때문에 인프라 `apply`를 실행해야 하는 상황을 없앴습니다.

---

## 사용 AWS 서비스 및 도구

**AWS**

![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-FF9900?style=flat-square&logo=amazoneks&logoColor=white)
![Amazon VPC](https://img.shields.io/badge/Amazon%20VPC-232F3E?style=flat-square&logo=amazonaws&logoColor=white)
![AWS ALB](https://img.shields.io/badge/ALB-FF9900?style=flat-square&logo=amazonaws&logoColor=white)
![Amazon S3](https://img.shields.io/badge/Amazon%20S3-569A31?style=flat-square&logo=amazons3&logoColor=white)
![CloudFront](https://img.shields.io/badge/CloudFront-8C4FFF?style=flat-square&logo=amazonaws&logoColor=white)
![Amazon ECR](https://img.shields.io/badge/Amazon%20ECR-FF9900?style=flat-square&logo=amazonecs&logoColor=white)
![Route53](https://img.shields.io/badge/Route53-8C4FFF?style=flat-square&logo=amazonroute53&logoColor=white)
![IAM](https://img.shields.io/badge/IAM-DD344C?style=flat-square&logo=amazonaws&logoColor=white)
![EBS](https://img.shields.io/badge/EBS-FF9900?style=flat-square&logo=amazonaws&logoColor=white)
![EC2](https://img.shields.io/badge/EC2-FF9900?style=flat-square&logo=amazonec2&logoColor=white)

**IaC**

![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat-square&logo=terraform&logoColor=white)
![HCL](https://img.shields.io/badge/HCL-000000?style=flat-square&logo=terraform&logoColor=white)

**Kubernetes / GitOps**

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Helm](https://img.shields.io/badge/Helm-0F1689?style=flat-square&logo=helm&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-EF7B4D?style=flat-square&logo=argo&logoColor=white)

**모니터링**

![Elasticsearch](https://img.shields.io/badge/Elasticsearch-005571?style=flat-square&logo=elasticsearch&logoColor=white)
![Kibana](https://img.shields.io/badge/Kibana-005571?style=flat-square&logo=kibana&logoColor=white)

---

## Terraform 모듈 구조

```
koco/
├── backend/                  # Terraform state 백엔드(S3 + DynamoDB) 부트스트랩 전용
├── environments/
│   ├── dev/                  # dev root module — vpc_ip_range 10.110.0.0/16, domain koco-test.click
│   └── prod/                 # prod root module — vpc_ip_range 10.120.0.0/16, domain ktbkoco.com
└── modules/                  # 로컬 모듈 10개
    ├── vpc/                  # VPC, 3계층(public/service/db)×2AZ 서브넷, IGW, NAT, 라우팅 테이블
    ├── security_group/        # openvpn/ec2/db용 보안 그룹
    ├── openvpn/               # 퍼블릭 서브넷 OpenVPN EC2(관리자 접근용 VPN 게이트웨이)
    ├── db_instance/           # EC2 기반 MySQL 서버(고정 프라이빗 IP, S3 백업 복원)
    ├── iam/                   # 노드그룹 Role, ALB Controller IAM Role(Pod Identity), EBS CSI IRSA Role
    ├── service_account/       # ALB Controller용 Kubernetes ServiceAccount
    ├── helm/                  # ALB Controller + ArgoCD Helm 배포, ArgoCD Ingress, Route53 레코드 5개
    ├── s3_static_site/        # 프론트엔드 정적 호스팅 S3(CloudFront OAI 전용 접근)
    ├── cdn/                   # CloudFront 배포 + Route53(루트/www 레코드)
    └── ecr/                   # 컨테이너 이미지 저장소
```

원격 모듈: `terraform-aws-modules/eks/aws` (`~>20.0`) — EKS 클러스터/노드그룹/애드온을 담당하며, 로컬 `modules/eks`는 별도로 두지 않았습니다.

**설계 의도**: `environments/dev`, `environments/prod` 두 root module은 `vpc → security_group → openvpn → db → eks → sa → iam → helm → s3_static_site → cdn → ecr` 11개 모듈을 완전히 동일한 순서로 호출합니다. 두 환경의 차이는 CIDR 대역·도메인명·S3/ECR 네이밍 같은 변수값에만 있고 구조 자체는 동일하게 유지해, dev에서 검증한 인프라 토폴로지가 prod에서도 그대로 재현되도록 했습니다.

모듈 간 의존성은 output→input 참조로 구성됩니다.

```
koco_vpc ──→ koco_security_group ──→ openvpn / db
koco_vpc ──→ eks (vpc_id, service_az1/az2_id)
iam.eks_node_group_role_arn ──→ eks (노드그룹 IAM 역할)
eks(cluster_oidc_issuer_url, oidc_provider_arn) ──→ iam (IRSA/Pod Identity 구성)
sa(namespace/name) ──→ iam (Pod Identity Association) ──→ helm
helm.alb_dns ──→ cdn (ALB API 오리진)
s3_static_site ⇄ cdn (OAI arn / bucket name 상호 참조)
```

`eks`↔`iam`, `s3_static_site`↔`cdn` 두 지점은 모듈 단위로 보면 순환 참조처럼 보이지만, 실제로는 각 모듈 내부의 서로 다른 리소스가 서로 다른 방향으로 참조하고 있어 Terraform이 리소스 단위 그래프로 순서를 정상적으로 풀어냅니다.

**State 관리**: S3 버킷(`koco-terraformstate`) + DynamoDB 테이블(동일 이름 재사용)로 원격 state와 잠금을 구성했습니다.

---

## EKS 클러스터 구성

| 항목 | 값 |
|---|---|
| 클러스터 버전 | `1.32` (dev/prod 동일) |
| 엔드포인트 접근 | Public + Private 동시 활성화 |
| 노드그룹 | `infra`(t3.medium, 4~5대, disk 30GB) / `app`(t3.medium, 1~2대, disk 3GB) |
| 클러스터 액세스 | Access Entry API 기반, `enable_cluster_creator_admin_permissions = true` |
| EKS 애드온 | `coredns`, `kube-proxy`, `vpc-cni`, `eks-pod-identity-agent` (모두 `most_recent = true`) |

**설계 의도 — 노드그룹 역할 분리**: `infra` 노드그룹은 ArgoCD·ELK 스택처럼 상시 구동되는 인프라 워크로드를, `app` 노드그룹은 Spring Boot 애플리케이션을 위해 분리했습니다. `node-group=infra` / `node-group=app` 라벨로 두 그룹을 구분해, 향후 `nodeSelector`/`tolerations`로 스케줄링을 세밀하게 제어할 수 있는 기반을 마련했습니다.

**설계 의도 — 원격 EKS 모듈 채택**: 노드그룹·애드온·OIDC Provider·Access Entry를 처음부터 직접 구현하는 대신 `terraform-aws-modules/eks/aws` v20을 사용해, 커뮤니티에서 검증된 표준 패턴으로 클러스터 생성 로직의 복잡도를 낮췄습니다.

**설계 의도 — `eks-pod-identity-agent` 애드온**: ALB Controller의 인증 방식을 Pod Identity로 전환하기 위한 전제 조건으로 포함했습니다(아래 [IAM 및 IRSA 설계](#iam-및-irsa-설계) 참조).

두 노드그룹 모두 `eks_managed_node_group_defaults.iam_role_arn`으로 동일한 `eks-node-group-role`을 공유합니다.

---

## Helm 배포 구성

`modules/helm`에서 Helm으로 2개의 컴포넌트를 배포합니다.

### AWS Load Balancer Controller

| 항목 | 값 |
|---|---|
| Chart | `aws-load-balancer-controller` (`1.7.1`, 버전 고정) |
| Namespace | `kube-system` |
| ServiceAccount | `serviceAccount.create = false` (기존 SA 사용) |
| 인증 방식 | **EKS Pod Identity** |

**설계 의도**: 처음에는 OIDC/IRSA 방식으로 설계했으나, ServiceAccount의 `eks.amazonaws.com/role-arn` 어노테이션 값과 IAM Role ARN을 연결하는 배선이 실제로는 끊어져 있었습니다(자세한 내용은 [IAM 및 IRSA 설계](#iam-및-irsa-설계) 참조). 이를 계기로 어노테이션 없이 `aws_eks_pod_identity_association`으로 직접 연결하는 Pod Identity 방식으로 전환해, 같은 종류의 배선 누락이 재발할 여지를 구조적으로 줄였습니다.

ArgoCD Ingress(`kubernetes.io/ingress.class=alb`, `group.name=koco-alb-group`, `scheme=internet-facing`)를 이 컨트롤러가 감지해 실제 ALB를 생성하고, 생성된 ALB를 조회해 Route53에 `argocd`/`kibana`/`api_root`/`api_www`/`apm` 5개 레코드를 alias로 등록합니다.

### ArgoCD

| 항목 | 값 |
|---|---|
| Chart | `argo-cd` (`5.51.6`) |
| Namespace | `argocd` (Helm이 신규 생성) |
| Service 타입 | `ClusterIP` |
| 외부 노출 | 별도 ALB Ingress(`argocd_ingress`) |

**설계 의도**: `server.extraArgs=--insecure` + `configs.params.server.insecure=true`로 ArgoCD 서버 자체는 TLS 없이(HTTP) 구동하고, TLS 종료는 ALB의 443 리스너가 전담하도록 했습니다. "엣지에서 TLS 종료, 내부는 평문"이라는 일반적인 ALB Ingress 패턴을 그대로 따른 것입니다.

배포된 ArgoCD는 GitOps 리포를 감지해 App of Apps 패턴으로 Elasticsearch/Kibana/Filebeat/Metricbeat/APM/Redis/Spring Boot 등 실제 워크로드를 `syncWave` 순서(Wave -1: EBS CSI Driver → Wave 0: StorageClass/metrics-server → Wave 1: Elasticsearch/Redis → Wave 2~4: Kibana/APM/Filebeat/Spring)에 따라 배포합니다. 스토리지 드라이버가 준비되기 전에 PVC를 요구하는 워크로드가 먼저 뜨는 문제를 이 순서 강제로 방지합니다.

### Terraform ↔ GitOps 역할 분리

이 프로젝트는 인프라(Terraform)와 애플리케이션(GitOps/ArgoCD)의 책임을 계층별로 명확히 나눕니다.

| 계층 | 이 리포 (Terraform) | GitOps 리포 (ArgoCD) |
|------|-------------------|---------------------|
| 네트워크 | VPC, 서브넷, SG, NAT | - |
| 컴퓨팅 | EKS 클러스터, 노드그룹 | - |
| IAM | IRSA/Pod Identity 역할 | SA 어노테이션으로 IRSA 소비 |
| 컨테이너 런타임 | ECR 레포지토리 | 이미지 pull (values.yaml) |
| 인그레스 컨트롤러 | ALB Controller 설치 + Pod Identity 연결 | Ingress 리소스 정의 |
| 스토리지(오브젝트) | S3, CloudFront, RDS(EC2 MySQL) | - |
| 스토리지(블록) | EBS CSI IRSA 역할 | EBS CSI Driver, PVC 관리 |
| 애플리케이션 배포 | - | Spring, ELK, Redis, 애드온 |
| DNS | Route53 레코드 5개 생성 | Ingress host 정의 |
| 인증서 | ACM ARN 변수 참조 (수동 발급) | values.yaml ARN 참조 |
| 시크릿 | - | spring-env-secret 관리 |

두 리포는 동일 AWS 계정/클러스터를 공유하며, 도메인·ACM ARN 등 공유 값은 각 리포에서 별도 관리되므로 변경 시 두 리포를 모두 수정해야 합니다.

---

## IAM 및 IRSA 설계

| 역할 | 용도 | 인증 방식 |
|---|---|---|
| `eks-node-group-role` | EKS 노드그룹(EC2 워커) | `ec2.amazonaws.com` + `AmazonEKSWorkerNodePolicy`/`AmazonEBSCSIDriverPolicy` |
| `alb-ingress-sa-role` | ALB Controller | **EKS Pod Identity** |
| `AmazonEKS_EBS_CSI_Driver_IRSA` | EBS CSI Driver | OIDC/IRSA (Federated) |

### ALB Controller — IRSA에서 Pod Identity로 전환

처음 설계는 EKS의 표준 IRSA 패턴을 따랐습니다: OIDC Provider를 Federated 신뢰 주체로 하고, `sub`/`aud` 조건으로 특정 namespace·ServiceAccount만 역할을 assume하도록 제한하는 구조입니다. 하지만 실제 코드를 검증한 결과 이 체인이 두 지점에서 끊어져 있었습니다.

1. `modules/service_account`의 `sa-annotations` 기본값이 `eks.amazonaws.com/role-arn = ""`(빈 문자열)이었고, 루트 모듈에서 이를 override하지 않음
2. `modules/iam`이 `alb_ingress_sa_role`의 ARN을 output으로 노출하지 않아, override하려 해도 참조할 값 자체가 없었음

즉 ServiceAccount 어노테이션과 IAM Role ARN 두 곳을 서로 다른 모듈에서 정확히 맞춰야 하는 IRSA 방식의 구조적 특성 때문에 배선이 누락된 상태였습니다. 이를 근본적으로 해결하기 위해 인증 방식 자체를 **EKS Pod Identity**로 전환했습니다.

```hcl
resource "aws_iam_role" "alb_ingress_sa_role" {
  name = var.role-alc_role_name
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "alb_ingress" {
  cluster_name    = var.cluster_name
  namespace       = var.role-alc-namespace
  service_account = var.role-alc-sa_name
  role_arn        = aws_iam_role.alb_ingress_sa_role.arn
  depends_on      = [aws_iam_role.ebs_csi_irsa_role]
}
```

- IAM Role의 신뢰 주체를 OIDC Federated에서 `Principal.Service = pods.eks.amazonaws.com`으로 교체
- `aws_eks_pod_identity_association`으로 클러스터/네임스페이스/ServiceAccount/Role ARN을 한 리소스에서 직접 연결 — ServiceAccount 어노테이션이나 `sub`/`aud` 조건 문자열 매칭이 더 이상 필요 없음
- `modules/iam/outputs.tf`에 `alb_ingress_sa_role_arn` output을 추가하고, `modules/service_account`의 `sa-annotations` 기본값을 `{}`로 정리
- 모듈 의존성은 `module.sa → module.iam → module.helm`의 **일방향 DAG**로 단순화됨

**IRSA와 Pod Identity의 차이**: IRSA는 ServiceAccount 어노테이션에 Role ARN을 심어두고 OIDC 토큰 교환으로 인증하는 방식이라 "어노테이션 값"과 "IAM 측 신뢰 정책 조건" 두 곳이 문자열 수준까지 일치해야 합니다. Pod Identity는 `aws_eks_pod_identity_association`이라는 단일 리소스가 이 연결을 코드로 명시하기 때문에, 이번에 겪은 것과 같은 배선 누락 가능성이 구조적으로 낮습니다.

### EBS CSI Driver — 기존 IRSA 유지

EBS CSI Driver용 `ebs_csi_irsa_role`은 이번 전환 대상에서 제외하고 기존 OIDC/IRSA 방식을 그대로 유지했습니다. 이 리포(Terraform)만 보면 신뢰 대상 ServiceAccount(`kube-system:ebs-csi-controller-sa`)가 어디서도 생성되지 않는 것처럼 보이지만, GitOps 리포의 ArgoCD Application(`ebs-csi-driver-application.yaml`)을 직접 검증한 결과 해당 Application이 만드는 ServiceAccount의 namespace·이름·Role ARN 어노테이션이 Terraform의 신뢰 정책 조건과 정확히 일치함을 확인했습니다. 두 리포를 함께 봐야 정상 동작이 확인되는 "리포 간 역할 분리" 구조이며, ALB Controller처럼 한 리포 안에서 실제로 배선이 끊어진 경우와는 본질적으로 다른 케이스입니다.

---

## 네트워크 설계

VPC를 퍼블릭 / 서비스(프라이빗) / DB(프라이빗) 3계층 × 2개 가용영역(`ap-northeast-2a`, `ap-northeast-2c`) = 총 6개 `/24` 서브넷으로 분리했습니다.

| 서브넷 역할 | 특징 |
|---|---|
| 퍼블릭 | OpenVPN, IGW 라우팅. `kubernetes.io/role/elb=1` 태그로 외부 ALB 배치 대상 |
| 서비스(프라이빗) | **EKS 클러스터/노드그룹 전용 배치**. `kubernetes.io/role/internal-elb=1` 태그 |
| DB(프라이빗) | MySQL EC2 인스턴스 전용 배치 |

**설계 의도**: EKS 클러스터와 노드는 프라이빗 서비스 서브넷에만 두고, 외부 진입점은 ALB(및 그 앞단의 CloudFront)로 한정해 공격 표면을 좁혔습니다. 퍼블릭/서비스 서브넷에 EKS용 태그(`role/elb`, `role/internal-elb`)를 미리 붙여 AWS Load Balancer Controller가 서브넷을 자동 탐색할 수 있도록 준비했습니다.

**라우팅**: IGW 1개(퍼블릭용), NAT 게이트웨이 1개(`public-az1`에만 배치)로 구성했습니다. 서비스/DB 서브넷은 하나의 프라이빗 라우팅 테이블을 공유하며, 두 계층 간 격리는 라우팅이 아닌 보안 그룹 레벨에서 이뤄집니다.

**보안 그룹**: `sg_openvpn`(SSH/HTTPS/OpenVPN 포트), `sg_ec2`(Spring/FastAPI 포트, VPC CIDR 허용), `sg_db`(MySQL 포트, OpenVPN 경유만 허용)로 구성했습니다. 애플리케이션 포트(8080/8000)는 SG 참조 대신 VPC CIDR 전체 허용 방식을 택해, "VPC 내부망은 신뢰한다"는 전제를 SG 설계 전반에 일관되게 적용했습니다. 이 전제는 GitOps 리포의 ELK/Redis 무인증 설정과도 동일한 설계 철학을 공유합니다.

**DNS**: Route53에 `argocd`/`kibana`/`api_root`/`api_www`/`apm` 5개 레코드를 ALB로, `cdn_root`/`cdn_www` 2개 레코드를 CloudFront로 alias 연결했습니다.

---

## 스토리지 / CDN / 이미지 레지스트리

### S3 (`s3_static_site` 모듈)
- 프론트엔드 정적 빌드 산출물(HTML/JS/CSS 등) 호스팅 전용 버킷입니다.
- 버킷 자체를 직접 서비스하지 않고 아래 CloudFront의 오리진(`s3_origin_config` + OAI)으로만 연결되는 구조입니다.
- Public Access Block 4개 옵션을 모두 활성화해 S3에 대한 직접 퍼블릭 접근을 완전히 차단하고, 버킷 정책으로 CloudFront OAI에게만 `s3:GetObject`를 허용합니다.

### CloudFront (`cdn` 모듈)
- 오리진 2개로 구성됩니다: S3(정적 프론트엔드) + ALB-Spring(`custom_origin_config`, API 서버).
- `/oauth/*`, `/api/*` 경로(`path_pattern`)는 ALB-Spring 오리진으로, 그 외 나머지 경로는 S3 오리진으로 분기해 정적 자산과 API 트래픽을 하나의 배포에서 함께 서빙합니다.
- `aws_cloudfront_origin_access_identity`(OAI)로 S3에 대한 직접 접근을 차단하고 CloudFront를 통한 접근만 허용합니다.
- `viewer_certificate`에 `acm_certificate_arn`을 지정하고 모든 behavior에서 `viewer_protocol_policy=redirect-to-https`로 설정해 HTTPS를 강제합니다(`minimum_protocol_version=TLSv1.2_2021`).
- 정적 자산은 기본 1시간(최대 24시간) 엣지 캐싱을 적용해 응답 속도를 개선하고, `/api`, `/oauth` 경로는 TTL 0으로 캐시하지 않도록 구성했습니다.

### ECR (`ecr` 모듈)
- Spring Boot 등 컨테이너 이미지를 저장하는 프라이빗 레지스트리이며, dev/prod 환경별로 저장소를 분리(`dev-ecr-repo`/`prod-ecr-repo`)했습니다.
- GitOps 리포의 Deployment/`values.yaml`이 이 레지스트리의 이미지를 pull하는 경로로 사용합니다.
- `scan_on_push=true`로 이미지 푸시 시 자동 취약점 스캔을 활성화했으며, 태그 정책은 `image_tag_mutability=MUTABLE`(기본값)입니다.

### EC2 MySQL (`db_instance` 모듈)
- Amazon RDS 대신 EC2 인스턴스에 `user_data`로 MySQL을 직접 설치하는 자체 관리형 방식(`aws_instance.mysql_server`)입니다. **비용 문제로 RDS 대신 EC2 기반 자체 관리형 MySQL을 선택**했습니다. 그 대신 Multi-AZ 자동 장애조치나 정기 백업 같은 RDS의 관리형 기능은 직접 구현해야 하는 트레이드오프를 안고 있습니다.
- DB 전용 프라이빗 서브넷(단일 AZ)에 고정 프라이빗 IP로 배치되며, 보안 그룹은 OpenVPN을 경유한 접근만 허용하도록 구성했습니다.
- 초기 부팅 시 S3에 저장된 백업 파일을 1회 복원하는 스크립트가 포함되어 있습니다.

---

## 실행 방법

### 사전 준비
- Terraform, AWS CLI 설치 및 자격 증명 설정
- Terraform state용 S3 버킷/DynamoDB 테이블이 아직 없다면 `koco/backend/`를 먼저 apply해 부트스트랩
- **ACM 인증서 수동 발급 필요**: 이 리포에는 `aws_acm_certificate` 리소스가 없습니다. `aws acm request-certificate`로 인증서를 직접 발급한 뒤, 발급받은 ARN을 `environments/<env>/variables.tf`의 `acm_certificate_arn`에 채워 넣어야 합니다.

### 실행 순서

dev와 prod는 별도의 root module이므로, AWS 프로파일도 환경에 맞게 분리해서 실행합니다.

```bash
# dev 환경
cd koco/environments/dev
AWS_PROFILE=dev terraform init
AWS_PROFILE=dev terraform plan
AWS_PROFILE=dev terraform apply

# prod 환경
cd koco/environments/prod
AWS_PROFILE=prod terraform init
AWS_PROFILE=prod terraform plan
AWS_PROFILE=prod terraform apply
```

> 더 자세한 기술 분석은 [📋 상세 기술 분석 문서](./docs/analysis/final_analysis.md)를 참고해주세요.

---

## 연관 프로젝트

### GitOps Repository

🔗 [kakaotech-21-iceT-gitops](https://github.com/KIMSEOKWON00/kakaotech-21-iceT-gitops)

이 Terraform 리포와 함께 동작하는 GitOps 리포입니다.

| 항목 | 이 리포 (Terraform) | GitOps 리포 |
|------|-------------------|------------|
| 역할 | AWS 인프라 프로비저닝 | 애플리케이션 배포 관리 |
| 도구 | Terraform | ArgoCD + Helm |
| 관리 대상 | EKS, VPC, IAM, ec2 등 | Spring, ELK, Redis 등 |

**연동 방식:**
- 이 리포가 EKS 클러스터와 ArgoCD를 프로비저닝
- ArgoCD가 GitOps 리포를 감시하며 워크로드 자동 배포
- IAM IRSA/Pod Identity 역할은 이 리포에서 생성하고 GitOps 리포의 ServiceAccount가 소비하는 구조


