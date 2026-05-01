#!/bin/bash
# Graceful KVM Virtual Machine Shutdown Script
# Helps with patching the hypervisor when the automatic reboot handling acts a bit funny

# Maximum time (in seconds) to wait for all VMs to power off
TIMEOUT=300
CHECK_INTERVAL=5

echo "Checking for running Virtual Machines..."

# Fetch only currently running VMs by name
RUNNING_VMS=$(virsh list --state-running --name)

# Exit early if nothing is running
if [[ -z "${RUNNING_VMS}" ]]; then
    echo "No running VMs found."
    exit 0
fi

echo "Initiating graceful shutdown for the following VMs:"
echo "${RUNNING_VMS}"
echo "----------------------------------------------------"

# Loop through and send the ACPI shutdown signal to each running VM
for VM in ${RUNNING_VMS}; do
    echo "Sending shutdown signal to: ${VM}"
    virsh shutdown "${VM}"
done

echo "----------------------------------------------------"
echo "Waiting for VMs to power off (Timeout limit: ${TIMEOUT}s)..."

# Wait loop to ensure VMs actually shut down
ELAPSED=0
while [[ -n "$(virsh list --state-running --name)" ]] && [[ "${ELAPSED}" -lt "${TIMEOUT}" ]]; do
    sleep "$CHECK_INTERVAL"
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
    # Print progress on the same line
    echo -ne "Waiting... ${ELAPSED}s elapsed\r"
done

# Print a newline after the progress loop finishes
echo ""

# Check if any VMs are still running after the timeout
REMAINING_VMS=$(virsh list --state-running --name)
if [[ -n "${REMAINING_VMS}" ]]; then
    echo "WARNING: Time-out reached. The following VMs failed to shut down gracefully:"
    echo "${REMAINING_VMS}"
    echo ""
    echo "Action required: Log into the guests to check for hung processes, or use 'virsh destroy <vm_name>' to force a hard power-off."
    exit 1
else
    echo "SUCCESS: All Virtual Machines have safely shut down."
    exit 0
fi
