locals {
  ssh_public_key_path = pathexpand(var.ssh_public_key_path)
  ssh_public_key      = trimspace(file(local.ssh_public_key_path))
}

resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-24.04-noble-cloudimg-amd64.qcow2"
  pool   = var.libvirt_pool
  source = var.ubuntu_cloud_image_url
  format = "qcow2"
}

resource "libvirt_volume" "root" {
  name           = "${var.vm_name}.qcow2"
  pool           = var.libvirt_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = var.vm_disk_bytes
}

resource "libvirt_cloudinit_disk" "seed" {
  name = "${var.vm_name}-seed.iso"
  pool = var.libvirt_pool
  user_data = templatefile("${path.module}/templates/user-data.yml.tftpl", {
    hostname            = var.vm_hostname
    admin_user          = var.admin_user
    security_agent_user = var.security_agent_user
    ssh_public_key      = local.ssh_public_key
  })
}

resource "libvirt_domain" "vm" {
  name      = var.vm_name
  memory    = var.vm_memory_mib
  vcpu      = var.vm_vcpus
  autostart = true
  cloudinit = libvirt_cloudinit_disk.seed.id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.root.id
  }

  network_interface {
    network_name   = var.libvirt_network
    wait_for_lease = true
    hostname       = var.vm_hostname
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}
