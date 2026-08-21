terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.8.2"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = var.cloudflare_account_id
  name       = var.tunnel_name
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

resource "cloudflare_zero_trust_access_identity_provider" "one_time_pin" {
  account_id = var.cloudflare_account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config = {
    ingress = [
      {
        hostname = "${var.hello_hostname}.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "grafana.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "openbao.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "n8n.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "n8n.${var.cloudflare_prod_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_dns_record" "hello" {
  zone_id = var.cloudflare_zone_id
  name    = "${var.hello_hostname}.${var.cloudflare_zone_name}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_zero_trust_access_application" "hello" {
  account_id                = var.cloudflare_account_id
  name                      = "Homelab test app"
  domain                    = "${var.hello_hostname}.${var.cloudflare_zone_name}"
  type                      = "self_hosted"
  session_duration          = "24h"
  auto_redirect_to_identity = false
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.one_time_pin.id]
  app_launcher_visible      = false

  policies = [
    {
      name     = "Allow owner email"
      decision = "allow"
      include = [
        {
          email = {
            email = var.access_allowed_email
          }
        }
      ]
    }
  ]
}

resource "cloudflare_dns_record" "grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana.${var.cloudflare_zone_name}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_zero_trust_access_application" "grafana" {
  account_id                = var.cloudflare_account_id
  name                      = "Homelab Grafana"
  domain                    = "grafana.${var.cloudflare_zone_name}"
  type                      = "self_hosted"
  session_duration          = "24h"
  auto_redirect_to_identity = false
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.one_time_pin.id]
  app_launcher_visible      = false

  policies = [
    {
      name     = "Allow owner email"
      decision = "allow"
      include = [
        {
          email = {
            email = var.access_allowed_email
          }
        }
      ]
    }
  ]
}

resource "cloudflare_dns_record" "openbao" {
  zone_id = var.cloudflare_zone_id
  name    = "openbao.${var.cloudflare_zone_name}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_zero_trust_access_application" "openbao" {
  account_id                = var.cloudflare_account_id
  name                      = "Homelab OpenBao"
  domain                    = "openbao.${var.cloudflare_zone_name}"
  type                      = "self_hosted"
  session_duration          = "24h"
  auto_redirect_to_identity = false
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.one_time_pin.id]
  app_launcher_visible      = false

  policies = [
    {
      name     = "Allow owner email"
      decision = "allow"
      include = [
        {
          email = {
            email = var.access_allowed_email
          }
        }
      ]
    }
  ]
}

resource "cloudflare_dns_record" "n8n" {
  zone_id = var.cloudflare_zone_id
  name    = "n8n.${var.cloudflare_zone_name}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_zero_trust_access_application" "n8n" {
  account_id                = var.cloudflare_account_id
  name                      = "Homelab n8n"
  domain                    = "n8n.${var.cloudflare_zone_name}"
  type                      = "self_hosted"
  session_duration          = "24h"
  auto_redirect_to_identity = false
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.one_time_pin.id]
  app_launcher_visible      = false

  policies = [
    {
      name     = "Allow owner email"
      decision = "allow"
      include = [
        {
          email = {
            email = var.access_allowed_email
          }
        }
      ]
    }
  ]
}

resource "cloudflare_dns_record" "n8n_prod" {
  zone_id = var.cloudflare_prod_zone_id
  name    = "n8n.${var.cloudflare_prod_zone_name}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  sensitive = true
}
