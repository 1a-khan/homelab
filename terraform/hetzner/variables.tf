variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "lookup_server_name" {
  type        = string
  description = "Deprecated single existing Hetzner server name to inspect before importing. Prefer lookup_server_names."
  default     = ""
}

variable "lookup_server_names" {
  type        = list(string)
  description = "Existing Hetzner server names to inspect before importing."
  default     = []
}

variable "managed_servers" {
  description = "Hetzner servers managed by OpenTofu after explicit import."
  type = map(object({
    name                    = string
    server_type             = string
    image                   = string
    location                = optional(string)
    datacenter              = optional(string)
    ssh_keys                = optional(list(string), [])
    backups                 = optional(bool, false)
    labels                  = optional(map(string), {})
    firewall_ids            = optional(list(number), [])
    user_data               = optional(string)
    public_net_ipv4_enabled = optional(bool, true)
    public_net_ipv6_enabled = optional(bool, true)
  }))
  default = {}
}
