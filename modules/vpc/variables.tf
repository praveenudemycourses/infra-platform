variable "project_name" {
  description = "The name of the project for which the VPC is being created."
  type        = string

  validation {
    condition     = length(var.project_name) > 2
    error_message = "Project name must contain at least 3 characters."
  }
}

variable "environment" {
  description = "The environment for which the VPC is being created (e.g., dev, staging, prod)."
  type        = string

  validation {
    condition = contains(
      ["dev", "staging", "prod"],
      var.environment
    )
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "cidr_block" {
  description = "The CIDR block for the VPC (e.g., 10.0.0.0/16)"
  type        = string

  validation {
    condition = (
      can(cidrhost(var.cidr_block, 0)) &&
      tonumber(split("/", var.cidr_block)[1]) >= 16 &&
      tonumber(split("/", var.cidr_block)[1]) <= 28
    )

    error_message = "CIDR block must be valid CIDR notation with prefix length between /16 and /28."
  }
}

variable "availability_zones" {
  description = <<-EOT
    List of AWS Availability Zones to deploy subnets into.
    Example: ["us-east-1a", "us-east-1b", "us-east-1c"]
    Rules:
      - Minimum 2 (required for High Availability)
      - Maximum 6 (AWS regions have at most 6 AZs)
      - Must match count of public_subnet_cidrs and private_subnet_cidrs
      - No duplicates — each AZ must be unique
  EOT
  type = list(string)

  # Guard 1 — minimum 2 AZs for HA
  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones required for High Availability."
  }

  # Guard 2 — maximum 6 AZs (AWS hard limit per region)
  validation {
    condition     = length(var.availability_zones) <= 6
    error_message = "No AWS region has more than 6 Availability Zones. Check your input."
  }

  # Guard 3 — enforce AWS AZ naming format (e.g. us-east-1a, eu-west-2c)
  validation {
    condition = alltrue([
      for az in var.availability_zones :
      can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", az))
    ])
    error_message = "Each AZ must follow AWS format: '<region><letter>' (e.g. 'us-east-1a', 'eu-west-1b')."
  }

  # Guard 4 — no duplicate AZs (same AZ twice = false HA)
  validation {
    condition     = length(var.availability_zones) == length(toset(var.availability_zones))
    error_message = "availability_zones must not contain duplicates. Each AZ must be unique."
  }
}


variable "public_subnet_cidrs" {
  description = <<-EOT
    List of CIDR blocks for public subnets — one per Availability Zone.
    Example: ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
    Rules:
      - Count MUST match availability_zones count exactly
      - Minimum 2 (HA requirement)
      - Maximum 6 (AWS max AZs per region)
      - Each CIDR must be between /16 and /28
      - No duplicate CIDRs
      - Must not overlap with private_subnet_cidrs
    Instances in public subnets receive public IPs automatically.
  EOT
  type = list(string)

  # Guard 1 — minimum 2 for HA
  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "At least 2 public_subnet_cidrs required for High Availability."
  }

  # Guard 2 — maximum 6 (no AWS region has more than 6 AZs)
  validation {
    condition     = length(var.public_subnet_cidrs) <= 6
    error_message = "public_subnet_cidrs cannot exceed 6 (max AZs in any AWS region)."
  }

  # Guard 3 — validate format AND correct prefix range per CIDR
  validation {
    condition = alltrue([
      for cidr in var.public_subnet_cidrs :
      can(cidrhost(cidr, 0)) &&                    # valid CIDR format
      tonumber(split("/", cidr)[1]) >= 16 &&        # not larger than /16 (too big)
      tonumber(split("/", cidr)[1]) <= 28           # not smaller than /28 (too few IPs)
    ])
    error_message = "Each public subnet CIDR must be valid with prefix length between /16 and /28 (e.g. '10.0.1.0/24')."
  }

  # Guard 4 — no duplicate CIDRs (toset removes dupes; count diff = duplicate found)
  validation {
    condition     = length(var.public_subnet_cidrs) == length(toset(var.public_subnet_cidrs))
    error_message = "public_subnet_cidrs must not contain duplicate CIDR blocks."
  }
}

variable "private_subnet_cidrs" {
  description = "A list of CIDR blocks for the private subnets (e.g., [\"10.0.3.0/24\", \"10.0.4.0/24\"])"
  type        = list(string)

validation {

      condition = length(var.private_subnet_cidrs) >= 2
        error_message = "At least 2 private_subnet_cidrs required for High Availability."

}

   validation {

    condition = length(var.private_subnet_cidrs) <= 6

    error_message = "private_subnet_cidrs cannot exceed 6 (max AZs in any AWS region)."
   
   }

    validation {
    
          condition = alltrue([
            for cidr in var.private_subnet_cidrs :
            can(cidrhost(cidr, 0)) &&                    # valid CIDR format
            tonumber(split("/", cidr)[1]) >= 16 &&        # not larger than /16 (too big)
            tonumber(split("/", cidr)[1]) <= 28           # not smaller than /28 (too few IPs)
          ])
      

      error_message = "Each private subnet CIDR must be valid with prefix length between /16 and /28 (e.g. '10.0.3.0/24')."

    }

    }

variable "tags" {
  description = "A map of tags to apply to all resources in the VPC module."
  type        = map(string)
  default     = {}
}

variable "enable_nat_gateway" {

  description = "Whether to create a NAT Gateway for private subnets to access the internet. (true/false)"
  type        = bool
  default     = false
}
