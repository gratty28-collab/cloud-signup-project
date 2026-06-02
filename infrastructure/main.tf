terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Stores infrastructure state securely in AWS S3
  backend "s3" {
    bucket         = "terraformstatefile-kego" # Change this to a unique bucket name you own
    key            = "prod/infrastructure.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# 1. NETWORKING LAYER (VPC)
# Real-world best practice: Keep nodes private, expose only the Load Balancer
data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

# Public Subnets (For Load Balancer)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.environment}-public-${count.index}"
    # Crucial tag: Allows AWS to automatically discover subnets for Public Load Balancers
    "kubernetes.io/role/elb" = "1"
  }
}

# Private Subnets (For K8s Worker Nodes & App)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-${var.environment}-private-${count.index}"
    # Crucial tag: Allows AWS to discover subnets for Internal Load Balancers
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Internet Gateway & NAT Gateways
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Place NAT in public subnet
  tags          = { Name = "${var.project_name}-nat" }
}

# Routing
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# 2. AMAZON EKS CLUSTER (KUBERNETES)
# IAM Role for EKS Control Plane
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.environment}-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public.*.id, aws_subnet.private.*.id)
    endpoint_private_access = true
    endpoint_public_access  = true # Allows us to run kubectl commands from local machine / GitHub Actions
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}


# 3. EKS MANAGED NODE GROUP (WORKER NODES)
# IAM Role for Worker Nodes
resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess" # Gives pods permission to write to DynamoDB
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private.*.id # Keep instances out of the public eye!

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"] # Affordable but robust enough for basic K8s clusters

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}


# 4. DATABASE LAYER (DYNAMODB)
resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-${var.environment}-users-table"
  billing_mode = "PAY_PER_REQUEST" # Highly cost-efficient for a demo app
  hash_key     = "userId"

  attribute {
    name = "userId"
    type = "S" # Matches the Node.js application configure (email as string string key)
  }

  tags = {
    Environment = var.environment
  }
}

# Create the ECR Repository for the Application Images
resource "aws_ecr_repository" "app_repo" {
  name                 = "cloud-signup-app"
  image_tag_mutability = "MUTABLE"

  # Enforces scanning images for vulnerabilities on push (Great interview talking point!)
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = "production"
    Project     = "cloud-signup"
  }
}

# Automatically allow incoming Load Balancer traffic to EKS Worker NodePorts
resource "aws_security_group_rule" "eks_nodeport_inbound" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] # In production, you'd restrict this to the LB security group
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

  description = "Allow AWS Load Balancer to route traffic to Kubernetes NodePorts"
}

# 1. Fetch the TLS certificate from the EKS OIDC issuer (Required for the OIDC Provider)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 2. Create the OIDC Provider so IAM trusts your EKS Cluster
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 3. Create the IAM Policy allowing access to DynamoDB
resource "aws_iam_policy" "pod_dynamodb_policy" {
  name        = "${var.project_name}-${var.environment}-ddb-policy"
  description = "Allows EKS pods to write to the signup DynamoDB table"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem"
        ]
        Resource = "*" # In production, restrict this to your specific DynamoDB table ARN
      }
    ]
  })
}

# 4. Create the Trust Relationship (Assume Role Policy) binding IAM to the K8s Service Account
data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:default:signup-app-service-account"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

# 5. Create the IAM Role
resource "aws_iam_role" "pod_dynamodb_role" {
  name               = "${var.project_name}-${var.environment}-pod-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

# 6. Attach the policy to the role
resource "aws_iam_role_policy_attachment" "ddb_attach" {
  role       = aws_iam_role.pod_dynamodb_role.name
  policy_arn = aws_iam_policy.pod_dynamodb_policy.arn
}

# 7. Output the Role ARN so you can use it in your Kubernetes ServiceAccount manifest
output "app_iam_role_arn" {
  value       = aws_iam_role.pod_dynamodb_role.arn
  description = "Copy this ARN into your Kubernetes ServiceAccount annotation!"
}
