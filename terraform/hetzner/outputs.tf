output "lookup_server" {
  value = var.lookup_server_name == "" ? null : {
    id          = data.hcloud_server.lookup[0].id
    name        = data.hcloud_server.lookup[0].name
    server_type = data.hcloud_server.lookup[0].server_type
    status      = data.hcloud_server.lookup[0].status
    ipv4        = data.hcloud_server.lookup[0].ipv4_address
    ipv6        = data.hcloud_server.lookup[0].ipv6_address
    datacenter  = data.hcloud_server.lookup[0].datacenter
    location    = data.hcloud_server.lookup[0].location
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
      datacenter  = server.datacenter
      location    = server.location
    }
  }
}
