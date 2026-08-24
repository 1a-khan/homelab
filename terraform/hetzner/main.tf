data "hcloud_server" "lookup" {
  count = var.lookup_server_name == "" ? 0 : 1
  name  = var.lookup_server_name
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
