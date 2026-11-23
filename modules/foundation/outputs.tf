output "organization_id" {
  description = "AWS Organization ID"
  value       = var.create_organization ? aws_organizations_organization.org[0].id : null
}

output "organization_arn" {
  description = "AWS Organization ARN"
  value       = var.create_organization ? aws_organizations_organization.org[0].arn : null
}

output "gaming_ou_id" {
  description = "Gaming Workloads Organizational Unit ID"
  value       = var.create_organization ? aws_organizations_organizational_unit.gaming_ou[0].id : null
}

output "account_ids" {
  description = "Map of AWS Account logical names to AWS Account IDs"
  value       = var.create_organization ? { for k, v in aws_organizations_account.accounts : k => v.id } : {}
}

output "cicd_role_arn" {
  description = "IAM Role ARN for CI/CD GitHub Actions OIDC"
  value       = aws_iam_role.ci_cd_oidc.arn
}

output "kms_general_primary_arn" {
  description = "Multi-Region KMS general platform primary key ARN (eu-central-1)"
  value       = aws_kms_key.multiregion_general.arn
}

output "kms_general_primary_alias" {
  description = "Multi-Region KMS general platform primary key alias (eu-central-1)"
  value       = aws_kms_alias.multiregion_general_alias.name
}

output "kms_general_dr_arn" {
  description = "Multi-Region KMS general platform replica key ARN (eu-west-1)"
  value       = aws_kms_replica_key.multiregion_general_dr.arn
}

output "kms_general_dr_alias" {
  description = "Multi-Region KMS general platform replica key alias (eu-west-1)"
  value       = aws_kms_alias.multiregion_general_dr_alias.name
}

output "kms_crypto_shredding_primary_arn" {
  description = "Multi-Region KMS Crypto-Shredding primary key ARN (eu-central-1)"
  value       = aws_kms_key.crypto_shredding.arn
}

output "kms_crypto_shredding_primary_alias" {
  description = "Multi-Region KMS Crypto-Shredding primary key alias (eu-central-1)"
  value       = aws_kms_alias.crypto_shredding_alias.name
}

output "kms_crypto_shredding_dr_arn" {
  description = "Multi-Region KMS Crypto-Shredding replica key ARN (eu-west-1)"
  value       = aws_kms_replica_key.crypto_shredding_dr.arn
}

output "kms_crypto_shredding_dr_alias" {
  description = "Multi-Region KMS Crypto-Shredding replica key alias (eu-west-1)"
  value       = aws_kms_alias.crypto_shredding_dr_alias.name
}
