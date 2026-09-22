#!/usr/bin/env bash
# shellcheck shell=bash
# The Linux VM that hosts Android, managed through Lima.

vm_status() {
  local s
  s=$("$LIMACTL" list "$VM_NAME" --format '{{.Status}}' 2>/dev/null || true)
  printf '%s' "${s:-Missing}"
}
vm_exists()  { [ "$(vm_status)" != Missing ]; }
vm_running() { [ "$(vm_status)" = Running ]; }

# Size the VM from the host once; the values live in the config file after that.
vm_defaults() {
  if [ -z "$(config_get VM_CPUS)" ]; then config_set VM_CPUS "$(clamp $(( $(host_cpus) / 2 )) 2 6)"; fi
  # Android 14 plus ATAK plus software rendering and encoding at 2560x1440 exhausted 8 GiB.
  if [ -z "$(config_get VM_MEMORY)" ]; then config_set VM_MEMORY "$(clamp $(( $(host_mem_gb) / 3 )) 4 12)GiB"; fi
  if [ -z "$(config_get VM_DISK)" ]; then config_set VM_DISK 60GiB; fi
}

vm_config_render() {
  local out="$TAKWERX_STATE/takwerx.yaml"
  sed -e "s/@CPUS@/$(config_get VM_CPUS 4)/" \
      -e "s/@MEMORY@/$(config_get VM_MEMORY 6GiB)/" \
      -e "s/@DISK@/$(config_get VM_DISK 60GiB)/" \
      "$TAKWERX_APP/lima/takwerx.yaml.tmpl" >"$out"
  if [ "$(config_get NETWORK_MODE nat)" = bridged ]; then
    printf 'networks:\n- lima: bridged\n' >>"$out"
  fi
  printf '%s' "$out"
}

vm_create() {
  step "Creating the Linux VM ($(config_get VM_CPUS) CPUs, $(config_get VM_MEMORY) RAM); first boot downloads Ubuntu and takes a few minutes"
  "$LIMACTL" create --name="$VM_NAME" --tty=false "$(vm_config_render)" || die "Could not create the VM (see $LOG_FILE and $LIMA_HOME/$VM_NAME/serial*.log)"
}
vm_start() {
  if vm_running; then return 0; fi
  step "Starting the VM"
  "$LIMACTL" start --tty=false "$VM_NAME" || die "The VM did not start (limactl start $VM_NAME for details)"
}
vm_stop() {
  if vm_running; then step "Stopping the VM"; "$LIMACTL" stop "$VM_NAME" || warn "VM stop reported an error"; fi
}
vm_delete() { if vm_exists; then "$LIMACTL" delete --force "$VM_NAME"; fi; }

# vm_run 'shell command': runs as root inside the VM.
vm_run() { "$LIMACTL" shell --workdir=/ "$VM_NAME" sudo bash -c "$1"; }
vm_shell() { "$LIMACTL" shell --workdir=/ "$VM_NAME"; }

# Switch the instance between NAT and bridged. The VM must be stopped.
vm_set_network() {
  case "$1" in
    bridged) "$LIMACTL" edit --tty=false --set '.networks = [{"lima":"bridged"}]' "$VM_NAME" ;;
    nat)     "$LIMACTL" edit --tty=false --set '.networks = []' "$VM_NAME" ;;
  esac
}

vm_ip() { vm_run "ip -4 -o addr show scope global" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
