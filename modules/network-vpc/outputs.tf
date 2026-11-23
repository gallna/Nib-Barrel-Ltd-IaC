output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "The ARN of the VPC"
  value       = aws_vpc.this.arn
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets (ALB, NAT Gateways)"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "List of IDs of private application subnets (ECS Fargate, RDS Proxy)"
  value       = aws_subnet.app[*].id
}

output "isolated_data_subnet_ids" {
  description = "List of IDs of isolated data subnets (Aurora DB, Valkey, VPC Endpoints)"
  value       = aws_subnet.data[*].id
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs"
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "List of public IP addresses assigned to NAT Gateways"
  value       = aws_eip.nat[*].public_ip
}

output "vpc_endpoints_sg_id" {
  description = "Security Group ID protecting Interface VPC Endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

output "vpc_endpoint_interface_ids" {
  description = "Map of interface VPC endpoint names to their IDs"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}
