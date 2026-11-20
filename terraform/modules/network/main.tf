# Two public subnets, no NAT gateway (cost control: ~$33/month saved per NAT).
# Tasks get public IPs but their security group only accepts traffic from the ALB.
data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394:Only the first two AZs are used via slice(); later AZ additions do not change the result.
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

# Lock down the default security group (CIS 5.4).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:Public subnets by design (no NAT for cost); SGs restrict ingress to the ALB.
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Optional VPC flow logs (off by default to keep the demo cheap).
resource "aws_cloudwatch_log_group" "flow" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/${var.name_prefix}/vpc-flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count              = var.enable_flow_logs ? 1 : 0
  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
}

resource "aws_iam_role_policy" "flow" {
  count = var.enable_flow_logs ? 1 : 0
  role  = aws_iam_role.flow[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count           = var.enable_flow_logs ? 1 : 0
  vpc_id          = aws_vpc.this.id
  traffic_type    = "REJECT"
  log_destination = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn    = aws_iam_role.flow[0].arn
}
