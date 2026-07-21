##############################################################################
# LOCALS — name prefix & common tags used across all resources
##############################################################################
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##############################################################################
# FIX 1 — VALIDATION GUARD
# Catches public/private subnet count mismatch at plan time
# Without this → cryptic runtime error during apply
##############################################################################
resource "null_resource" "validate_subnet_az_match" {
  lifecycle {
    precondition {
      condition     = length(var.public_subnet_cidrs) == length(var.private_subnet_cidrs)
      error_message = "public_subnet_cidrs and private_subnet_cidrs must have the same number of entries. Got public=${length(var.public_subnet_cidrs)}, private=${length(var.private_subnet_cidrs)}."
    }
  }
}

##############################################################################
# VPC
##############################################################################
resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true           # required for Route53, ECS, RDS, EKS
  enable_dns_hostnames = true           # required for EC2 public DNS names
  instance_tenancy     = "default"      # explicit — "dedicated" costs ~10x more

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vpc"
    }
  )
}

##############################################################################
# INTERNET GATEWAY — allows public subnets to reach the internet
##############################################################################
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-igw"
    }
  )
}

##############################################################################
# PUBLIC SUBNETS
# for_each = map(string) where key=AZ, value=CIDR
# e.g. { "us-east-1a" = "10.0.1.0/24", "us-east-1b" = "10.0.2.0/24" }
##############################################################################
resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value           # CIDR from map value
  availability_zone       = each.key             # AZ from map key
  map_public_ip_on_launch = true                 # instances get public IPs

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name                     = "${local.name_prefix}-public-${each.key}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"             # EKS external load balancer tag
    }
  )
}

##############################################################################
# PRIVATE SUBNETS
# for_each = map(string) where key=AZ, value=CIDR
# e.g. { "us-east-1a" = "10.0.101.0/24", "us-east-1b" = "10.0.102.0/24" }
##############################################################################
resource "aws_subnet" "private" {
  for_each = var.private_subnet_cidrs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value           # CIDR from map value
  availability_zone       = each.key             # AZ from map key
  map_public_ip_on_launch = false                # never auto-assign public IP

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name                              = "${local.name_prefix}-private-${each.key}"
      Tier                              = "private"
      "kubernetes.io/role/internal-elb" = "1"    # EKS internal load balancer tag
    }
  )
}

##############################################################################
# ELASTIC IP — one per NAT Gateway
# FIX 2 — toset(["nat"]) not ["nat"] (list vs set bug)
# FIX 3 — prevent_destroy protects against accidental EIP deletion
#          losing an EIP means your NAT IP changes → firewall rules break
##############################################################################
resource "aws_eip" "nat" {
  # FIX 2: toset(["nat"]) is correct — for_each requires a set, not a list
  for_each = var.enable_nat_gateway ? toset(["nat"]) : toset([])

  domain = "vpc"    # replaces deprecated vpc = true

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-nat-eip"
    }
  )

  # FIX 3: prevent_destroy = true
  # If this EIP is destroyed → NAT GW gets a new public IP
  # Any external firewall whitelisting this IP will silently break
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_internet_gateway.main]   # IGW must exist before EIP
}

##############################################################################
# NAT GATEWAY
# FIX 4 — added count guard so it's not created when enable_nat_gateway=false
# Placed in first public subnet (NAT must live in a public subnet)
##############################################################################
resource "aws_nat_gateway" "main" {
  # FIX 4: count guard — without this, NAT tries to reference EIP that doesn't exist
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id     = values(aws_subnet.public)[0].id   # first public subnet
  allocation_id = aws_eip.nat["nat"].id              # EIP created above

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-nat-gateway"
    }
  )

  depends_on = [aws_internet_gateway.main]   # IGW must exist first
}

##############################################################################
# PUBLIC ROUTE TABLE
# Single route table shared by all public subnets
# Routes all internet traffic (0.0.0.0/0) → Internet Gateway
##############################################################################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-public-rt"
    }
  )
}

# Associate every public subnet with the public route table
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

##############################################################################
# PRIVATE ROUTE TABLES — one per AZ
# Each private subnet gets its own route table (better for HA and debugging)
##############################################################################
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-private-rt-${each.key}"
    }
  )
}

# FIX 5 — NAT route guard
# Only create NAT routes if NAT Gateway is enabled
# Without this guard → Terraform crashes trying to reference a NAT GW that doesn't exist
resource "aws_route" "private_nat_gateway" {
  # FIX 5: only create routes if NAT is enabled — empty map = no routes created
  for_each = var.enable_nat_gateway ? aws_route_table.private : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id   # [0] because count-based
}

# Associate every private subnet with its own private route table
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

##############################################################################
# FIX 6 — DEFAULT SECURITY GROUP LOCKDOWN
# AWS auto-creates a default SG that ALLOWS all traffic between members
# If any resource accidentally uses it → fully open internal network
# Solution: take ownership and remove all rules (deny all)
##############################################################################
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  # No ingress or egress blocks = deny all traffic
  # Name makes it obvious this SG should never be used

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-default-sg-DO-NOT-USE"
    }
  )
}

##############################################################################
# FIX 7 — NETWORK ACLs (subnet-level stateless firewall)
# NACLs are stateless — must explicitly allow both inbound AND outbound
# Acts as defense-in-depth layer below Security Groups
##############################################################################

# Public NACL — attached to all public subnets
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for s in aws_subnet.public : s.id]

  # INBOUND — allow HTTP from anywhere
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  # INBOUND — allow HTTPS from anywhere
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # INBOUND — allow ephemeral ports (return traffic from internet)
  # NACLs are stateless — without this, response packets are blocked
  # Ephemeral range 1024-65535 covers Linux (32768-60999) and Windows (49152-65535)
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # OUTBOUND — allow all traffic out
  # Return traffic direction is handled by Security Groups (stateful)
  egress {
    rule_no    = 100
    protocol   = "-1"   # -1 = all protocols
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-public-nacl"
    }
  )
}

# Private NACL — attached to all private subnets
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for s in aws_subnet.private : s.id]

  # INBOUND — allow all traffic from within the VPC only
  # Private subnets should never receive traffic from the public internet directly
  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.cidr_block   # only VPC-internal traffic
    from_port  = 0
    to_port    = 0
  }

  # INBOUND — allow ephemeral ports for return traffic via NAT Gateway
  # When private subnet calls internet via NAT, response comes back on ephemeral ports
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # OUTBOUND — allow all outbound (Security Groups handle fine-grained control)
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-private-nacl"
    }
  )
}

##############################################################################
# FIX 8 — VPC FLOW LOGS
# Captures metadata for ALL IP traffic (accepted + rejected)
# Required for: SOC2, PCI-DSS, HIPAA compliance + security incident response
# 3 resources needed: CloudWatch Log Group + IAM Role + Flow Log itself
##############################################################################

# CloudWatch Log Group — stores the flow log data
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/flow-logs/${local.name_prefix}"
  retention_in_days = var.flow_logs_retention_days   # configurable via variable

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-flow-logs"
    }
  )
}

# IAM Role — grants VPC Flow Logs service permission to write to CloudWatch
resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-flow-logs-role"

  # Trust policy — only vpc-flow-logs service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })

  tags = merge(local.common_tags, var.tags)
}

# IAM Role Policy — defines what the role can actually do
resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-flow-logs-policy"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# Flow Log — the actual resource that enables traffic capture
resource "aws_flow_log" "main" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"    # capture ACCEPT + REJECT + ALL traffic
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-flow-log"
    }
  )
}
