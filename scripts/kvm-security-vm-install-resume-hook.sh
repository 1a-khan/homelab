#!/usr/bin/env bash
set -euo pipefail

vm_name="${VM_NAME:-security-master}"
hook_path="/etc/systemd/system-sleep/99-${vm_name}-libvirt"

if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
  echo "VM '${vm_name}' does not exist yet. Create it first." >&2
  exit 1
fi

sudo tee "${hook_path}" >/dev/null <<HOOK
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
  post)
    /usr/bin/virsh start "${vm_name}" >/dev/null 2>&1 || true
    ;;
esac
HOOK

sudo chmod +x "${hook_path}"
virsh autostart "${vm_name}"

echo "Installed ${hook_path}"
echo "VM '${vm_name}' will autostart on boot and be started again after laptop resume."
