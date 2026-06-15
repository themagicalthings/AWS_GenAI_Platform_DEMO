# Unit tests for the network module. Offline via mock_provider.
#   terraform -chdir=terraform/modules/network init -backend=false
#   terraform -chdir=terraform/modules/network test

mock_provider "aws" {}

variables {
  name = "genai-ka-test"
}

run "vpc_and_subnet_topology" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.20.0.0/16"
    error_message = "VPC CIDR should default to 10.20.0.0/16"
  }
  assert {
    condition     = aws_vpc.this.enable_dns_hostnames == true
    error_message = "VPC must enable DNS hostnames (required for PrivateLink private DNS)"
  }
  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "Expected 2 public subnets"
  }
  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "Expected 2 private subnets"
  }
}

run "vpc_endpoints" {
  command = plan

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 7
    error_message = "Expected 7 interface endpoints"
  }
  assert {
    condition     = aws_vpc_endpoint.gateway_s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 endpoint must be Gateway type"
  }
  assert {
    condition     = alltrue([for e in aws_vpc_endpoint.interface : e.private_dns_enabled])
    error_message = "All interface endpoints must enable private DNS"
  }
}

run "endpoint_sg_only_allows_443_from_vpc" {
  command = plan

  assert {
    condition     = one(aws_security_group.endpoints.ingress).from_port == 443
    error_message = "Endpoint SG must only ingress on 443"
  }
  assert {
    condition     = contains(one(aws_security_group.endpoints.ingress).cidr_blocks, "10.20.0.0/16")
    error_message = "Endpoint SG ingress must be scoped to the VPC CIDR, not the internet"
  }
}
