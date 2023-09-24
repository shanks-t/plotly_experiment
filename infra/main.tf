terraform {
  required_version = "~> 1.4"
  backend "s3" {
    bucket = "plotly-ds07"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

locals {
  container_name = "plotly"
  container_port = 8080 # ! Must be same EXPORE port from our Dockerfile
  example        = "plotly-example"
  image_uri      = "127293717875.dkr.ecr.us-east-1.amazonaws.com/plotly"
}

variable "IMAGE_TAG" {}

provider "aws" {
  region = "us-east-1" # Feel free to change this

  default_tags {
    tags = { example = local.example }
  }
}

# * Give Docker permission to pusher Docker images to AWS
data "aws_caller_identity" "this" {}
data "aws_ecr_authorization_token" "this" {}
data "aws_region" "this" {}
locals { ecr_address = format("%v.dkr.ecr.%v.amazonaws.com", data.aws_caller_identity.this.account_id, data.aws_region.this.name) }


# * Create an AWS Virtual Private Cloud (VPC).
resource "aws_vpc" "this" { cidr_block = "10.0.0.0/16" }

# * Create Security Groups that will allow our future resources to make and receive
# * requests from the internet (e.g. people can visit our hello world application).
resource "aws_security_group" "http" {
  description = "Permit incoming HTTP traffic"
  name        = "http"
  vpc_id      = resource.aws_vpc.this.id

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 80
    protocol    = "TCP"
    to_port     = 80
  }
}
resource "aws_security_group" "https" {
  description = "Permit incoming HTTPS traffic"
  name        = "https"
  vpc_id      = resource.aws_vpc.this.id

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 443
    protocol    = "TCP"
    to_port     = 443
  }
}
resource "aws_security_group" "egress_all" {
  description = "Permit all outgoing traffic"
  name        = "egress-all"
  vpc_id      = resource.aws_vpc.this.id

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
  }
}
resource "aws_security_group" "ingress_api" {
  description = "Permit some incoming traffic"
  name        = "ingress-esc-service"
  vpc_id      = resource.aws_vpc.this.id

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = local.container_port
    protocol    = "TCP"
    to_port     = local.container_port
  }
}

# * AWS requires us to use multiple Availability Zones and we only want to use
# * ones the are up and running so we find those ones here.
data "aws_availability_zones" "available" { state = "available" }

# * Create an Internet Gateway so that future resources running inside our VPC
# * can connect to the interent.
resource "aws_internet_gateway" "this" { vpc_id = resource.aws_vpc.this.id }

# * Create public subnetworks (Public Subnets) that are exposed to the interent
# * so that we can make and take requests.
resource "aws_route_table" "public" { vpc_id = resource.aws_vpc.this.id }
resource "aws_route" "public" {
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = resource.aws_internet_gateway.this.id
  route_table_id         = resource.aws_route_table.public.id
}
resource "aws_subnet" "public" {
  count = 2

  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = cidrsubnet(resource.aws_vpc.this.cidr_block, 8, count.index)
  vpc_id            = resource.aws_vpc.this.id
}
resource "aws_route_table_association" "public" {
  # https://github.com/hashicorp/terraform/issues/22476#issuecomment-547689853
  for_each = { for k, v in resource.aws_subnet.public : k => v.id }

  route_table_id = resource.aws_route_table.public.id
  subnet_id      = each.value
}

# * Eventually we will make private subnetworks (Private Subnets) that will
# * need to connect to external websites on the internet. To do this, we must
# * create a NAT Gateway that will route those requests from our Private Subnet
# * through our Public Subnets to actually reach those external websites.
resource "aws_eip" "this" { domain = "vpc" }
resource "aws_nat_gateway" "this" {
  allocation_id = resource.aws_eip.this.id
  subnet_id     = resource.aws_subnet.public[0].id # Just route all requests through one of our Public Subnets.

  depends_on = [resource.aws_internet_gateway.this]
}

# * Create Private Subnets on our VPC. This acts like an isolated sandbox
# * that we will run our future ECS Service inside of. Any requests to and
# * from the broader internet will be filtered throught our Public Subnets
# * and the NAT Gateway.
resource "aws_route_table" "private" { vpc_id = resource.aws_vpc.this.id }
resource "aws_route" "private" {
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = resource.aws_nat_gateway.this.id # Connect to NAT Gateway, not Internet Gateway
  route_table_id         = resource.aws_route_table.private.id
}
resource "aws_subnet" "private" {
  count = 2

  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = cidrsubnet(resource.aws_vpc.this.cidr_block, 8, count.index + length(resource.aws_subnet.public)) # Avoid conflicts with Public Subnets
  vpc_id            = resource.aws_vpc.this.id
}
resource "aws_route_table_association" "private" {
  # https://github.com/hashicorp/terraform/issues/22476#issuecomment-547689853
  for_each = { for k, v in resource.aws_subnet.private : k => v.id }

  route_table_id = resource.aws_route_table.private.id
  subnet_id      = each.value
}

# * Step 4 - Setting up our Application Load Balancers to manage incoming internet traffic.
# * Create an AWS Application Load Balancer that accepts HTTP requests (on port 80) and
# * forwards those requests to port 8080 (our container port) on the VPC where we will
# * eventually run our container.
resource "aws_lb" "this" {
  load_balancer_type = "application"

  depends_on = [resource.aws_internet_gateway.this]

  security_groups = [
    resource.aws_security_group.egress_all.id,
    resource.aws_security_group.http.id,
    resource.aws_security_group.https.id,
  ]

  subnets = resource.aws_subnet.public[*].id
}
resource "aws_lb_target_group" "this" {
  port        = local.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = resource.aws_vpc.this.id

  depends_on = [resource.aws_lb.this]
}
resource "aws_lb_listener" "this" {
  load_balancer_arn = resource.aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.this.arn
    type             = "forward"
  }
}

# * Step 5 - Create our ECS Cluster that our ECS Service will run inside of.
resource "aws_ecs_cluster" "this" { name = "${local.example}-cluster" }
resource "aws_ecs_cluster_capacity_providers" "this" {
  capacity_providers = ["FARGATE"]
  cluster_name       = resource.aws_ecs_cluster.this.name
}

# * Step 6 - Create our AWS ECS Task Definition which tells ECS how to run our
# * container (from our Docker Image).
data "aws_iam_policy_document" "this" {
  version = "2012-10-17"

  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
  }
}
resource "aws_iam_role" "this" { assume_role_policy = data.aws_iam_policy_document.this.json }
resource "aws_iam_role_policy_attachment" "default" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = resource.aws_iam_role.this.name
}
resource "aws_ecs_task_definition" "this" {
  container_definitions = jsonencode([{
    environment : [
      { name = "MY_INPUT_ENV_VAR", value = "terraform-modified-env-var" }
    ],
    essential    = true,
    image        = local.image_uri + ":" + var.IMAGE_TAG,
    name         = local.container_name,
    portMappings = [{ containerPort = local.container_port }],
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        "awslogs-region"        = "us-east-1", # Change this to your region
        "awslogs-group"         = "plotly",    # Change this to your CloudWatch Log Group name
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
  cpu                      = 256
  execution_role_arn       = aws_iam_role.this.arn
  family                   = "family-of-${local.example}-tasks"
  memory                   = 512
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
}


# * Step 7 - Run our application.
resource "aws_ecs_service" "this" {
  cluster         = resource.aws_ecs_cluster.this.id
  desired_count   = 1
  launch_type     = "FARGATE"
  name            = "${local.example}-service"
  task_definition = resource.aws_ecs_task_definition.this.arn

  lifecycle {
    ignore_changes = [desired_count] # Allow external changes to happen without Terraform conflicts, particularly around auto-scaling.
  }

  load_balancer {
    container_name   = local.container_name
    container_port   = local.container_port
    target_group_arn = resource.aws_lb_target_group.this.arn
  }

  network_configuration {
    security_groups = [
      resource.aws_security_group.egress_all.id,
      resource.aws_security_group.ingress_api.id,
    ]
    subnets = resource.aws_subnet.private[*].id
  }
}

# * Output the URL of our Application Load Balancer so that we can connect to
# * our application running inside  ECS once it is up and running.
output "lb_url" { value = "http://${resource.aws_lb.this.dns_name}" }