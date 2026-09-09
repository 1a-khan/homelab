output "security_vm" {
  value = {
    name                = libvirt_domain.vm.name
    hostname            = var.vm_hostname
    admin_user          = var.admin_user
    security_agent_user = var.security_agent_user
    vcpus               = var.vm_vcpus
    memory_mib          = var.vm_memory_mib
    disk_bytes          = var.vm_disk_bytes
    network             = var.libvirt_network
    addresses           = libvirt_domain.vm.network_interface[0].addresses
  }
}

output "security_vm_ip" {
  value = try(libvirt_domain.vm.network_interface[0].addresses[0], null)
}
