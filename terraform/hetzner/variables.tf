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

variable "staging_servers" {
  description = "Disposable Hetzner staging servers created and destroyed by OpenTofu."
  type = map(object({
    name                    = string
    server_type             = string
    image                   = optional(string, "ubuntu-24.04")
    location                = optional(string, "nbg1")
    ssh_keys                = optional(list(string), [])
    backups                 = optional(bool, false)
    labels                  = optional(map(string), {})
    firewall_ids            = optional(list(number), [])
    user_data               = optional(string)
    public_net_ipv4_enabled = optional(bool, true)
    public_net_ipv6_enabled = optional(bool, true)
    network_id              = optional(number)
    network_ip              = optional(string)
    delete_protection       = optional(bool, false)
    rebuild_protection      = optional(bool, false)
  }))
  default = {}
}

variable "create_staging_firewall" {
  type        = bool
  description = "Create and attach a default staging firewall to every staging server."
  default     = true
}

variable "staging_firewall_name" {
  type        = string
  description = "Name for the shared staging firewall."
  default     = "miak-staging-default"
}

variable "staging_allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH on staging servers. Restrict this to your trusted IPs when possible."
  default     = ["0.0.0.0/0", "::/0"]
}

variable "staging_allow_public_web" {
  type        = bool
  description = "Allow public HTTP/HTTPS to staging servers."
  default     = true
}

variable "staging_allowed_web_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach HTTP/HTTPS on staging servers."
  default     = ["0.0.0.0/0", "::/0"]
}
