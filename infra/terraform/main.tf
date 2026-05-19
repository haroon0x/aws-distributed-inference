data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  az = data.aws_availability_zones.available.names[0]

  common_tags = {
    Project = var.project_name
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public"
  })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = local.az

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "gateway" {
  name        = "${var.project_name}-gateway"
  description = "Public API gateway"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP API"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-gateway-sg"
  })
}

resource "aws_security_group" "private" {
  name        = "${var.project_name}-private-workers"
  description = "Private engine and worker traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "iii HTTP from gateway"
    from_port       = 3111
    to_port         = 3111
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  ingress {
    description = "iii engine RPC inside VPC"
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description     = "SSH from gateway only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-sg"
  })
}

resource "aws_instance" "gateway" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.gateway_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.gateway.id]
  key_name               = var.key_name

  user_data = templatefile("${path.module}/user_data_gateway.sh.tftpl", {
    engine_private_ip = aws_instance.engine.private_ip
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-gateway"
    Role = "gateway"
  })
}

resource "aws_instance" "engine" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.engine_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.private.id]
  key_name               = var.key_name

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-engine"
    Role = "engine"
  })
}

resource "aws_instance" "caller" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.caller_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.private.id]
  key_name               = var.key_name

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-caller"
    Role = "caller-worker"
  })
}

resource "aws_instance" "inference" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.inference_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.private.id]
  key_name               = var.key_name

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-inference"
    Role = "inference-worker"
  })
}
