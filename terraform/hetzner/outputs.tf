output "lookup_servers" {
  value = {
    for name, server in data.hcloud_server.lookup : name => {
      id          = server.id
      name        = server.name
      server_type = server.server_type
      status      = server.status
      ipv4        = server.ipv4_address
      ipv6        = server.ipv6_address
      location    = server.location
    }
  }
}

output "managed_servers" {
  value = {
    for key, server in hcloud_server.servers : key => {
      id          = server.id
      name        = server.name
      server_type = server.server_type
      status      = server.status
      ipv4        = server.ipv4_address
      ipv6        = server.ipv6_address
      location    = server.location
    }
  }
}

output "staging_servers" {
  value = {
    for key, server in hcloud_server.staging : key => {
      id          = server.id
      name        = server.name
      server_type = server.server_type
      status      = server.status
      ipv4        = server.ipv4_address
      ipv6        = server.ipv6_address
      location    = server.location
      private_ip  = try(hcloud_server_network.staging[key].ip, null)
    }
  }
}

output "private_network" {
  value = var.create_private_network ? {
    id         = hcloud_network.private[0].id
    name       = hcloud_network.private[0].name
    ip_range   = hcloud_network.private[0].ip_range
    subnet     = hcloud_network_subnet.private[0].ip_range
    zone       = hcloud_network_subnet.private[0].network_zone
    gateway_ip = hcloud_network_subnet.private[0].gateway
  } : null
}
