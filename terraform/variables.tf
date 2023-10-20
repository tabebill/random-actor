# Define default AWS region
variable "region" {
  type    = string
  default = "us-east-1"
}

# Define key pair name
variable "key_name" {
    type = string
    default = "my_keypair"
}

# Define the GitHub repository URL
variable "github_repo_url" {
  type    = string
  default = "https://github.com/tabebill/random-actor.git"
}

# Define the name of your Docker image repository in ECR
variable "ecr_repository_name" {
  type    = string
  default = "my-docker-repo"
}

# Define Docker image name
variable "docker_image_name" {
    type  = string
    default= "random-actor"
}

# Define the CodePipeline artifact bucket name
variable "artifact_bucket_name" {
  type    = string
  default = "my-codepipeline-artifacts"
}

