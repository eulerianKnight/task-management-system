module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    for name, config in var.node_groups : name => {
      name = "${var.cluster_name}-${name}"

      instance_types = config.instance_types
      capacity_type  = config.capacity_type

      min_size     = config.min_size
      max_size     = config.max_size
      desired_size = config.desired_size

      disk_size = config.disk_size

      # Use the latest EKS optimized AMI
      ami_type = "AL2_x86_64"

      # Security groups
      vpc_security_group_ids = [aws_security_group.node_group_sg.id]

      # IAM roles
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      labels = {
        Environment = var.environment
        NodeGroup   = name
      }

      taints = {}

      tags = {
        Environment = var.environment
        NodeGroup   = name
      }
    }
  }

  # Cluster access entry
  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/TeamRole"
      username = "team-role"
      groups   = ["system:masters"]
    },
  ]

  # Cluster logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Environment = var.environment
  }
}

# Additional security group for node groups
resource "aws_security_group" "node_group_sg" {
  name_prefix = "${var.cluster_name}-node-group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow nodes to communicate with each other"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-node-group-sg"
    Environment = var.environment
  }
}