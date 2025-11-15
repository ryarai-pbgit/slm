# aws eks update-kubeconfig --region ap-northeast-1 --name myslm20251113-eks
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0" 

  name                   = "${var.project_name}-eks"
  kubernetes_version     = "1.33"
  endpoint_public_access = true

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }    
  }
  # VPC設定
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    example = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = ["g5.xlarge"]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 200
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
        http_protocol_ipv6          = "disabled"
        instance_metadata_tags      = "disabled"
      }

      min_size     = 1
      max_size     = 1
      desired_size = 1
    }
  }

  # アクセスエントリ（CLIユーザーとマネジメントコンソールユーザー）
  access_entries = var.eks_access_entries

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# EBS CSI Driver用のIAMロール
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.project_name}-ebs-csi-driver"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}