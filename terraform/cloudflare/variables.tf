variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "cloudflare_zone_name" {
  type        = string
  description = "Domain name in Cloudflare, for example example.com."
}

variable "cloudflare_prod_zone_id" {
  type        = string
  description = "Production Cloudflare zone ID, for example the zone for miak-it.com."
}

variable "cloudflare_prod_zone_name" {
  type        = string
  description = "Production domain name in Cloudflare, for example miak-it.com."
  default     = "miak-it.com"
}

variable "tunnel_name" {
  type    = string
  default = "mini-pc-k3s-prod"
}

variable "hello_hostname" {
  type        = string
  description = "Subdomain part only, for example 'hello' for hello.example.com."
  default     = "hello"
}

variable "access_allowed_email" {
  type        = string
  description = "Email address allowed through Cloudflare Access for the test app."
  default     = "ammadkhan@msn.com"
}
