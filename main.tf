provider "aws" {
  region = "us-east-1"
}

# Generate a new SSH key pair
resource "tls_private_key" "strapi_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.strapi_key.private_key_pem
  filename        = "${path.module}/JDstrapi-key.pem"
  file_permission = "0600"
}

resource "aws_key_pair" "strapi_key" {
  key_name   = "JDstrapi-key"
  public_key = tls_private_key.strapi_key.public_key_openssh
}

# Create a VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Create an Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Create a subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

# Create a route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Associate route table with subnet
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Create security group
resource "aws_security_group" "strapi_sg" {
  name        = "strapi_sg"
  description = "Allow SSH and Strapi ports"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Strapi"
    from_port   = 1337
    to_port     = 1337
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
 
# Launch EC2 instance
resource "aws_instance" "strapi" {
  ami                         = "ami-00a929b66ed6e0de6" # Amazon Linux 2 AMI (HVM), SSD Volume Type
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.strapi_sg.id]
  key_name                    = aws_key_pair.strapi_key.key_name

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "StrapiServer"
  }

user_data = <<-EOF
  #!/bin/bash
  exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
  set -e

  yum update -y
  curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
  yum install -y nodejs git gcc-c++ make python3

  npm install -g pm2 npx

  mkdir -p /home/ec2-user/strapi
  chown ec2-user:ec2-user /home/ec2-user/strapi

  su - ec2-user -c "
    cd /home/ec2-user/strapi
    npx create-strapi-app my-project --quickstart --no-run --yes
    cd my-project
    npm install
    npm run build
    pm2 start 'npm run develop -- --host=0.0.0.0' --name strapi
    pm2 startup systemd
    pm2 save
  "
EOF


}

output "public_ip" {
  value = aws_instance.strapi.public_ip
}
