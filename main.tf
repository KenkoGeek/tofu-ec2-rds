terraform {
  required_version = ">= 1.11.0"
  backend "http" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "us-east-2"
}

variable "db_password" {
  type      = string
  sensitive = true
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "demo-vpc" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "demo-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "demo-public-rt" }
}

# --- Subnets ---
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "demo-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "demo-public-b" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Security Groups ---
resource "aws_security_group" "ec2" {
  name   = "demo-ec2-sg"
  vpc_id = aws_vpc.main.id

  # Salida a internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "demo-ec2-sg" }
}

resource "aws_security_group" "rds" {
  name   = "demo-rds-sg"
  vpc_id = aws_vpc.main.id

  # Solo MySQL desde el SG de EC2
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "demo-rds-sg" }
}

resource "aws_security_group_rule" "ec2_to_rds" {
  type                     = "egress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ec2.id
  source_security_group_id = aws_security_group.rds.id
}

# --- EC2 ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  tags                   = { Name = "demo-ec2" }
}

# --- RDS MySQL ---
resource "aws_db_subnet_group" "main" {
  name       = "demo-db-subnet"
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags       = { Name = "demo-db-subnet" }
}

resource "aws_db_instance" "mysql" {
  identifier             = "demo-mysql"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = "demo"
  username               = "admin"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
  tags                   = { Name = "demo-mysql" }
}

# --- Outputs ---
output "ec2_public_ip" {
  value = aws_instance.app.public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.endpoint
}
