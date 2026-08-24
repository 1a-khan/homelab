locals {
  lookup_server_names = toset(
    distinct(
      compact(
        concat(var.lookup_server_names, [var.lookup_server_name])
      )
    )
  )

  staging_firewall_ids = var.create_staging_firewall && length(var.staging_servers) > 0 ? [hcloud_firewall.staging_default[0].id] : []
  staging_network_servers = {
    for key, server in var.staging_servers : key => server
    if server.network_id != null
  }
}

data "hcloud_server" "lookup" {
  for_each = local.lookup_server_names
  name     = each.value
}

resource "hcloud_server" "servers" {
  for_each = var.managed_servers

  name         = each.value.name
  server_type  = each.value.server_type
  image        = each.value.image
  location     = each.value.location
  datacenter   = each.value.datacenter
  ssh_keys     = each.value.ssh_keys
  backups      = each.value.backups
  labels       = merge(each.value.labels, { managed_by = "opentofu" })
  firewall_ids = each.value.firewall_ids
  user_data    = each.value.user_data

  public_net {
    ipv4_enabled = each.value.public_net_ipv4_enabled
    ipv6_enabled = each.value.public_net_ipv6_enabled
  }

  delete_protection  = true
  rebuild_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_firewall" "staging_default" {
  count = var.create_staging_firewall && length(var.staging_servers) > 0 ? 1 : 0

  name = var.staging_firewall_name
  labels = {
    managed_by  = "opentofu"
    environment = "staging"
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.staging_allowed_ssh_cidrs
  }

  dynamic "rule" {
    for_each = var.staging_allow_public_web ? toset(["http"]) : toset([])
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "80"
      source_ips = var.staging_allowed_web_cidrs
    }
  }

  dynamic "rule" {
    for_each = var.staging_allow_public_web ? toset(["https"]) : toset([])
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "443"
      source_ips = var.staging_allowed_web_cidrs
    }
  }
}

resource "hcloud_server" "staging" {
  for_each = var.staging_servers

  name         = each.value.name
  server_type  = each.value.server_type
  image        = each.value.image
  location     = each.value.location
  ssh_keys     = each.value.ssh_keys
  backups      = each.value.backups
  labels       = merge(each.value.labels, { managed_by = "opentofu", environment = "staging" })
  firewall_ids = concat(each.value.firewall_ids, local.staging_firewall_ids)
  user_data    = each.value.user_data

  public_net {
    ipv4_enabled = each.value.public_net_ipv4_enabled
    ipv6_enabled = each.value.public_net_ipv6_enabled
  }

  delete_protection  = each.value.delete_protection
  rebuild_protection = each.value.rebuild_protection
}

resource "hcloud_server_network" "staging" {
  for_each = local.staging_network_servers

  server_id  = hcloud_server.staging[each.key].id
  network_id = each.value.network_id
  ip         = each.value.network_ip
}
