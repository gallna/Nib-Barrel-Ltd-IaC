output "global_accelerator_ips" {
  description = "Static Anycast IP addresses assigned to Global Accelerators per API"
  value       = { for k, v in aws_globalaccelerator_accelerator.api : k => v.ip_sets[0].ip_addresses }
}

output "global_accelerator_arns" {
  description = "Map of Global Accelerator ARNs per API"
  value       = { for k, v in aws_globalaccelerator_accelerator.api : k => v.id }
}

output "arc_cluster_arn" {
  description = "Route 53 ARC cluster ARN"
  value       = aws_route53recoverycontrolconfig_cluster.gaming.arn
}

output "arc_cluster_endpoints" {
  description = "Route 53 ARC cluster regional endpoints for data-plane recovery actions"
  value       = aws_route53recoverycontrolconfig_cluster.gaming.cluster_endpoints
}

output "arc_routing_control_arns" {
  description = "Map of Route 53 ARC routing control ARNs per service"
  value       = { for k, v in aws_route53recoverycontrolconfig_routing_control.services : k => v.arn }
}

output "cloudfront_distribution_id" {
  description = "ID of CloudFront distribution for Dienekes Plaza Web"
  value       = aws_cloudfront_distribution.web.id
}

output "cloudfront_distribution_domain" {
  description = "Domain name of CloudFront distribution for Dienekes Plaza Web"
  value       = aws_cloudfront_distribution.web.domain_name
}

output "waf_web_acl_arn" {
  description = "Regional WAF Web ACL ARN for Application Load Balancers"
  value       = aws_wafv2_web_acl.regional_alb.arn
}

output "waf_cloudfront_acl_arn" {
  description = "CloudFront Global WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "web_static_bucket_id" {
  description = "S3 bucket ID for Dienekes Plaza Web static assets"
  value       = aws_s3_bucket.web_static.id
}

output "web_static_bucket_arn" {
  description = "S3 bucket ARN for Dienekes Plaza Web static assets"
  value       = aws_s3_bucket.web_static.arn
}
