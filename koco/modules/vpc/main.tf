#=============================================#
# VPC 생성
resource "aws_vpc" "aws-vpc" {
  cidr_block           = var.vpc_ip_range
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(tomap({
         Name = "vpc-${var.stage}-${var.servicename}"}), 
        var.tags)
}

#=============================================#
#subnet 생성
resource "aws_subnet" "public-az1" {
  vpc_id                  = aws_vpc.aws-vpc.id
  cidr_block              = var.subnet_public_az1
  map_public_ip_on_launch = true
  availability_zone       = element(var.az, 0)

  tags = merge(tomap({
    Name                                          = "subnet-pub-az1-${var.stage}-${var.servicename}",
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared", #shared는 여러 클러스터가 공유할 수 있음을 의미하며, owned는 특정 클러스터가 독점
    "kubernetes.io/role/elb"                      = "1" # EKS에서 퍼블릭 LoadBalancer (Classic ELB, ALB) 를 만들 때, 이 태그가 있어야 퍼블릭 서브넷으로 인식
  }), var.tags)

  depends_on = [aws_vpc.aws-vpc]
}
resource "aws_subnet" "public-az2" {
  vpc_id                  = aws_vpc.aws-vpc.id
  cidr_block              = var.subnet_public_az2
  map_public_ip_on_launch = true
  availability_zone       = element(var.az, 1)

  tags = merge(tomap({
    Name                                          = "subnet-pub-az2-${var.stage}-${var.servicename}",
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared",
    "kubernetes.io/role/elb"                      = "1"
  }), var.tags)

  depends_on = [aws_vpc.aws-vpc]
}
resource "aws_subnet" "service-az1" {
  vpc_id                  = aws_vpc.aws-vpc.id
  cidr_block              = var.subnet_service_az1
  map_public_ip_on_launch = false
  availability_zone       = element(var.az, 0)

  tags = merge(tomap({
    Name                                          = "subnet-svc-az1-${var.stage}-${var.servicename}",
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared",
    "kubernetes.io/role/internal-elb"             = "1" # 내부용 LoadBalancer (internal ELB) 를 위한 서브넷으로 지정
    # EKS에서 internal 유형의 서비스 (Service type: LoadBalancer + internal)를 만들 때 이 서브넷이 선택
  }), var.tags)

  depends_on = [aws_vpc.aws-vpc]
}
resource "aws_subnet" "service-az2" {
  vpc_id                  = aws_vpc.aws-vpc.id
  cidr_block              = var.subnet_service_az2
  map_public_ip_on_launch = false
  availability_zone       = element(var.az, 1)

  tags = merge(tomap({
    Name                                          = "subnet-svc-az2-${var.stage}-${var.servicename}",
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared",
    "kubernetes.io/role/internal-elb"             = "1"
  }), var.tags)

  depends_on = [aws_vpc.aws-vpc]
}
resource "aws_subnet" "db-az1" {
  vpc_id                  = aws_vpc.aws-vpc.id
  cidr_block              = var.subnet_db_az1
  map_public_ip_on_launch = false
  availability_zone       = element(var.az, 0)

  tags = merge(tomap({
         Name = "subnet-db-az1-${var.stage}-${var.servicename}"}), 
        var.tags)

  depends_on = [aws_vpc.aws-vpc]
}
resource "aws_subnet" "db-az2" {
  vpc_id                  = aws_vpc.aws-vpc.id
  cidr_block              = var.subnet_db_az2
  map_public_ip_on_launch = false
  availability_zone       = element(var.az, 1)
  tags = merge(tomap({
         Name = "subnet-db-az2-${var.stage}-${var.servicename}"}), 
        var.tags)
  depends_on = [
    aws_vpc.aws-vpc
  ]
}

#=============================================#
# igw 생성
resource "aws_internet_gateway" "vpc-igw" {
  vpc_id = aws_vpc.aws-vpc.id
  tags = merge(tomap({
         Name = "igw-${var.stage}-${var.servicename}"}), 
        var.tags)
}

#=============================================#
# EIP for NAT 생성
resource "aws_eip" "nat-eip" {
  depends_on = [aws_internet_gateway.vpc-igw]

  tags = merge(
    tomap({
      Name = "eip-nat-${var.stage}-${var.servicename}"
    }),
    var.tags
  )
}

#=============================================#
# NAT 생성
resource "aws_nat_gateway" "vpc-nat" {
  allocation_id = aws_eip.nat-eip.id
  subnet_id     = aws_subnet.public-az1.id
  depends_on = [aws_internet_gateway.vpc-igw, 
                aws_eip.nat-eip]
  tags = merge(tomap({
         Name = "nat-${var.stage}-${var.servicename}"}), 
        var.tags)    
}

#=============================================#
#routetable 생성 및 라우팅 테이블에 게이트웨이 연결
resource "aws_route_table" "aws-rt-pub" { # 퍼블릭 라우팅 테이블 생성
  vpc_id = aws_vpc.aws-vpc.id
  tags = merge(tomap({
         Name = "rt-pub-${var.stage}-${var.servicename}"}), 
        var.tags)
}
resource "aws_route" "route-to-igw" { # 인터넷 게이트웨이 라우트
  route_table_id         = aws_route_table.aws-rt-pub.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.vpc-igw.id
  lifecycle { # 새 리소스를 먼저 만든 다음, 기존 리소스를 삭제
    create_before_destroy = true
  }
}

resource "aws_route_table" "aws-rt-pri" { # NAT Gateway 라우팅 테이블 생성
  vpc_id = aws_vpc.aws-vpc.id
  tags = merge(tomap({
         Name = "aws-rt-pri-${var.stage}-${var.servicename}"}), 
        var.tags)
}
resource "aws_route" "route-to-nat" { # NAT Gateway 라우트
  route_table_id         = aws_route_table.aws-rt-pri.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.vpc-nat.id
}

#=============================================#
# 라우팅 테이블 연결
resource "aws_route_table_association" "public-az1" {
 subnet_id      = aws_subnet.public-az1.id
 route_table_id = aws_route_table.aws-rt-pub.id
}
resource "aws_route_table_association" "public-az2" {
 subnet_id      = aws_subnet.public-az2.id
 route_table_id = aws_route_table.aws-rt-pub.id
}
resource "aws_route_table_association" "service-az1" {
 subnet_id      = aws_subnet.service-az1.id
 route_table_id = aws_route_table.aws-rt-pri.id
}
resource "aws_route_table_association" "service-az2" {
 subnet_id      = aws_subnet.service-az2.id
 route_table_id = aws_route_table.aws-rt-pri.id
}
resource "aws_route_table_association" "db-az1" {
 subnet_id      = aws_subnet.db-az1.id
 route_table_id = aws_route_table.aws-rt-pri.id
}
resource "aws_route_table_association" "db-az2" {
 subnet_id      = aws_subnet.db-az2.id
 route_table_id = aws_route_table.aws-rt-pri.id
}