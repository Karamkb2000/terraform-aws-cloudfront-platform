output "cloudfront_url" {
  value = "https://${module.cdn.distribution_domain_name}"
}

output "alb_dns_name" {
  value = module.web.alb_dns_name
}

output "assets_bucket" {
  value = module.storage.bucket_name
}
