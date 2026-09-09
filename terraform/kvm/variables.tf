variable "libvirt_uri" {
  type        = string
  description = "Local libvirt connection URI."
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  type        = string
  description = "Libvirt storage pool for VM disks."
  default     = "default"
}

variable "libvirt_network" {
  type        = string
  description = "Libvirt network for the VM."
  default     = "default"
}

variable "vm_name" {
  type        = string
  description = "Name of the local security VM."
  default     = "security-master"
}

variable "vm_hostname" {
  type        = string
  description = "Hostname inside the local security VM."
  default     = "security-master"
}

variable "vm_vcpus" {
  type        = number
  description = "Maximum vCPUs available to the VM."
  default     = 4
}

variable "vm_memory_mib" {
  type        = number
  description = "RAM assigned to the VM in MiB."
  default     = 8192
}

variable "vm_disk_bytes" {
  type        = number
  description = "Root disk size in bytes."
  default     = 128849018880
}

variable "ubuntu_cloud_image_url" {
  type        = string
  description = "Ubuntu cloud image URL."
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "admin_user" {
  type        = string
  description = "Full admin user created by cloud-init and managed by Ansible."
  default     = "adm-master"
}

variable "security_agent_user" {
  type        = string
  description = "Low-privilege user for authenticated security checks."
  default     = "security-agent"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Public SSH key path for initial access."
  default     = "~/.ssh/hetzner_admin_ed25519.pub"
}
