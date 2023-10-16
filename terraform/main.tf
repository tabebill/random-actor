# Required provider and terrarform backend
terraform {
    required_providers{
        aws = {
            source = "hashicorp/aws"
            version = "~>4.0"
        }
    }
    backend "s3"{
        bucket = "my-terraform-state-bucket"
        key = "aws/ec2-deploy/terraform.tfstate"
    }
}

# AWS provider and region
provider "aws" {
    region = var.region 
}

# S3 bucket for remote backend
resource "aws_s3_bucket" "terraform_state_bucket" {
    bucket = "my-terraform-state-bucket"
    acl    = "private"
}

# S3 bucket for artifact storage
resource "aws_s3_bucket" "codepipeline_artifact_bucket" {
  bucket = "my-codepipeline-artifacts"
}

# VPC (Virtual Private Cloud)
resource "aws_vpc" "my_vpc" {
    cidr_block = "10.0.0.0/16" # Adjust the CIDR block as needed
    enable_dns_support = true
    enable_dns_hostnames = true
}

# Public subnet
resource "aws_subnet" "public_subnet" {
    vpc_id                  = aws_vpc.my_vpc.id
    cidr_block              = "10.0.1.0/24" # Adjust as needed
    availability_zone       = "us-east-1a" # Adjust the AZ as needed
    map_public_ip_on_launch = true
}

# Internet Gateway (IGW)
resource "aws_internet_gateway" "my_igw" {
    vpc_id = aws_vpc.my_vpc.id
}

# Attach IGW to the VPC
resource "aws_vpc_attachment" "my_igw_attachment" {
    vpc_id             = aws_vpc.my_vpc.id
    internet_gateway_id = aws_internet_gateway.my_igw.id
}

# SSH key pair
resource "aws_key_pair" "my_key_pair" {
    key_name   = var.key_name
    public_key = var.public_key
}

# Security group
resource "aws_security_group" "my_security_group" {
    name        = "my-security-group"
    description = "Security group for SSH and HTTP"

  # Ingress rule for SSH
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
  }

  # Ingress rule for HTTP
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress rule for all ports
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instance profile IAM role
resource "aws_iam_role" "my_iam_role" {
    name = "ECR-LOGIN-AUTO"
    assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [
        {
            Action = "sts:AssumeRole",
            Effect = "Allow",
            Principal = {
            Service = "ec2.amazonaws.com"
            }
        }
        ]
    })
}

# Attach policies to the IAM role
resource "aws_iam_policy_attachment" "my_iam_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    roles      = [aws_iam_role.my_iam_role.name]
}

# IAM instance profile
resource "aws_iam_instance_profile" "my_instance_profile" {
    name = "my-instance-profile"
    role = [aws_iam_role.my_iam_role.name]
}

# Launch Template
resource "aws_launch_template" "my_lt" {
    name = "my-launch-template"
    version = "1"
    image_id = "ami-041feb57c611358bd"
    instance_type = "t2.micro"
    key_name = [aws_key_pair.my_key_pair.key_name]
    vpc_security_group_ids = [aws_security_group.my_security_group.name]
    iam_instance_profile = [aws_iam_instance_profile.my_instance_profile.name]
    user_data = <<-EOF
        #!/bin/bash
        # Install Docker
        sudo amazon-linux-extras install -y docker
        sudo service docker start
        
        # Authenticate with ECR (use AWS CLI v2 for this)
        aws ecr get-login-password --region ${data.aws_region.current.name} | docker login --username AWS --password-stdin ${data.aws_account_id.current.id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com
        
        # Pull and run the Docker image from ECR
        docker pull ${terraform.output.docker_image_name}:latest
        docker run -d -p 80:80 ${terraform.output.docker_image_name}:latest
        EOF
    block_device_mappings {
        # Custom block device mapping for the root volume.
        device_name = "/dev/xvda"
        ebs {
        volume_size = 20
        volume_type = "gp2"
        }
    }
}

# Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "my_asg" {
    name = "my-asg"
    launch_template {
        id      = aws_launch_template.my_lt.id
        version = "$Latest"
    }
    min_size             = 1
    max_size             = 3
    desired_capacity     = 2
    availability_zones   = ["us-east-1a"] # Adjust the AZs as needed(but based on what was set in the subnet)
    vpc_zone_identifier  = [aws_subnet.public_subnet.id]
    health_check_type    = "EC2"
    default_cooldown     = 300
    target_group_arns    = [aws_lb_target_group.my_target_group.arn]
}

# Create an Application Load Balancer (ALB)
resource "aws_lb" "my_alb" {
    name               = "my-alb"
    internal           = false
    load_balancer_type = "application"
    subnets            = [aws_subnet.public_subnet.id]
    enable_deletion_protection = false # For demo purposes
}

# Create a target group for the ALB
resource "aws_lb_target_group" "my_target_group" {
    name     = "my-tg"
    port     = 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.my_vpc.id
    target_type = "instance"

    health_check {
        path                = "/"
        protocol            = "HTTP"
        port                = "traffic-port"
        interval            = 30
        timeout             = 10
        healthy_threshold   = 2
        unhealthy_threshold = 2
    }
}

# Attach ASG to the target group
resource "aws_autoscaling_attachment" "asg_attachment" {
    autoscaling_group_name = [aws_autoscaling_group.my_asg.name]
    lb_target_group_arn  = [aws_lb_target_group.my_target_group.arn]
}

# ECR repository
resource "aws_ecr_repository" "docker_repo" {
    name = var.ecr_repository_name
}
output "ecr_repository_uri" {
    value = aws_ecr_repository.docker_repo.repository_url
}

# Create an AWS Elastic Beanstalk application
resource "aws_beanstalk_application" "my_beanstalk_app" {
    name = "my-beanstalk-app"
}

# Create an AWS Elastic Beanstalk environment for the test environment
resource "aws_beanstalk_environment" "my_beanstalk_env" {
    name                = "my-beanstalk-env"
    application         = aws_beanstalk_application.my_beanstalk_app.name
    solution_stack_name = "64bit Amazon Linux 2 v5.4.4 running Docker 19.03.13-ce"
    # Additional environment settings
}

# Create a CodeBuild project for building the Docker image
resource "aws_codebuild_project" "build_project" {
    name          = "docker-build-project"
    description   = "Build Docker image from GitHub"
    service_role  = aws_iam_role.codebuild_role.arn
    artifacts {
        type = "NO_ARTIFACTS"
    }
    environment {
        compute_type = "BUILD_GENERAL1_SMALL"
        image        = "aws/codebuild/standard:5.0"
        environment_variables = {
            AWS_REGION       = var.region
            ECR_REPO_URI     = aws_ecr_repository.docker_repo.repository_url
            GITHUB_REPO_URL  = var.github_repo_url
            ECR_REPO_NAME    = var.ecr_repository_name
        }
    }
    source {
        type = "GITHUB"
        location = var.github_repo_url
    }
    phases {
        build {
            commands = [
                "echo Building Docker image...",
                "docker build -t ${var.ecr_repository_name}:${format("%d", timestamp())} .",
                "eval $$(aws ecr get-login --no-include-email --region ${var.region})",
                "docker push ${var.ecr_repository_name}:${format("%d", timestamp())}",
            ]
        }
  }
}
output "docker_image_name" {
  value = "${var.buildspec_environment["ECR_REPO_NAME"]}:${format("%d", timestamp())}"
}

# IAM role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
    name = "codebuild-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [
        {
            Action = "sts:AssumeRole",
            Effect = "Allow",
            Principal = {
            Service = "codebuild.amazonaws.com",
            },
        },
        ],
    })
}

# IAM policy for the CodeBuild role
resource "aws_iam_policy" "codebuild_policy" {
    name        = "codebuild-policy"
    description = "IAM policy for CodeBuild project"

    policy = jsonencode({
        Version = "2012-10-17",
        Statement = [
        {
            Action   = [
                "ecr:GetAuthorizationToken", 
                "ecr:BatchCheckLayerAvailability", 
                "ecr:GetDownloadUrlForLayer", 
                "ecr:GetRepositoryPolicy", 
                "ecr:ListImages", 
                "ecr:DescribeImages", 
                "ecr:BatchGetImage", 
                "ecr:GetLifecyclePolicy", 
                "ecr:GetLifecyclePolicyPreview"
            ],
            Effect   = "Allow",
            Resource = "*",
        },
        ],
    })
}

# Attach the IAM policy to the CodeBuild role
resource "aws_iam_role_policy_attachment" "codebuild_role_policy_attachment" {
    policy_arn = aws_iam_policy.codebuild_policy.arn
    role       = aws_iam_role.codebuild_role.name
}

# Create an AWS CodeDeploy application
resource "aws_codedeploy_app" "example" {
    name     = "MyCodeDeployApp"
    compute_platform = "ECS"
}

# Create a CodeDeploy Deployment Group for Elastic Beanstalk
resource "aws_codedeploy_deployment_group" "example" {
    app_name              = aws_codedeploy_app.example.name
    deployment_group_name = "MyDeploymentGroup"
    service_role_arn      = [aws_iam_role.codedeploy_role.arn]

    deployment_config {
        name = "CodeDeployDefault.ElasticBeanstalk.AllAtOnce"
    }

    auto_rollback_configuration {
        enabled = true
        events  = ["DEPLOYMENT_FAILURE"]
    }

    ec2_tag_set {
        ec2_tag_filter {
        key = "elasticbeanstalk:environment-name"
        type = "KEY_ONLY"
        }
    }

    trigger_configuration {
        trigger_events      = ["DeploymentFailure"]
        trigger_name        = "MyTrigger"
        trigger_target_arn  = aws_beanstalk_environment.my_beanstalk_env.arn
    }
}

# Create CodeDeploy role
resource "aws_iam_role" "codedeploy_role" {
  name = "CodeDeployRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
      }
    ]
  })

  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"]
}

# Attach CodeDeploy role to deployment group
resource "aws_iam_role_policy_attachment" "codedeploy_policy" {
  role = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# Output the CodeDeploy Deployment Group name
output "codedeploy_deployment_group_name" {
  value = aws_codedeploy_deployment_group.example.deployment_group_name
}


# Manual approval resource
resource "aws_codepipeline_action" "manual_approval" {
    name = "manual_approval"
    action_type_id = "Approval"
    category = "Approval"
    region = var.region
    owner = "AWS"
    version = "1"

    configuration = {
        Name = "Manual Approval"
    }
}

# Create a CodePipeline
resource "aws_codepipeline" "example" {
    name     = "example"
    role_arn = aws_iam_role.pipeline_role.arn

    artifact_store {
        location = aws_s3_bucket.codepipeline_artifact_bucket.id
        type     = "S3"
    }

    stage {
        name = "Source"
        action {
            name            = "Source"
            category        = "Source"
            owner           = "ThirdParty"
            provider        = "GitHub"
            version         = "1"
            output_artifacts = ["source_output"]
            configuration {
                Owner  = "tabebill"
                Repo   = "random-actor"
                Branch = "main"
                OAuthToken = data.github_actions_secret.oauth_token.value
            }
        }
    }

    stage {
        name = "Build"
        action {
            name            = "BuildAction"
            category        = "Build"
            owner           = "AWS"
            provider        = "CodeBuild"
            version         = "1"
            input_artifacts  = ["source_output"]
            output_artifacts = ["build_output"]
            configuration {
                ProjectName = aws_codebuild_project.build_project.name
            }
        }
    }

    stage {
        name = "Deploy"
        action {
            name            = "DeployAction"
            category        = "Deploy"
            owner           = "AWS"
            provider        = "ElasticBeanstalk"
            input_artifacts = ["build_output"]
            configuration {
                ApplicationName = aws_elastic_beanstalk_application.my_beanstalk_app.name
                EnvironmentName = aws_elastic_beanstalk_environment.my_beanstalk_env.name
            }
        }
    }

    stage {
        name = "Approval"
        action {
            name = "manual_approval"
            action_type_id = "Approval"
            category = "Approval"
            region = var.region
            owner = "AWS"
            provider = "CodePipeline"
            version = "1"

            configuration = {
                Name = "Manual Approval"
            }
        }
    }

    stage {
        
    }

}

# IAM role for the CodePipeline
resource "aws_iam_role" "pipeline_role" {
    name = "pipeline-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [
        {
            Action = "sts:AssumeRole",
            Effect = "Allow",
            Principal = {
            Service = "codepipeline.amazonaws.com",
            },
        },
        ],
    })
}

# Attach the necessary policies to the CodePipeline role
resource "aws_iam_policy_attachment" "codepipeline_role_attach" {
    name       = "codepipeline-role-attach"
    policy_arn = "arn:aws:iam::aws:policy/AWSCodePipeline_FullAccess"
    roles      = [aws_iam_role.pipeline_role.name]
}

output "codepipeline_name" {
    value = aws_codepipeline.example.name
}

data "github_actions_secret" "oauth_token" {
  secret_name = "github_oauth_token"
}

# Now you can use the token as needed
provider "github" {
  owner   = "tabebill"
  token   = data.github_actions_secret.oauth_token.value
}

