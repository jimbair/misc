#!/bin/bash
# Check if CentOS7 needs a reboot to apply the latest kernel
liveKernel=$(uname -r)
bootKernel=$(ls -t /boot/vmlinuz-3* | head -n 1 | cut -d \- -f 2-)
if [[ "${liveKernel}" != "${bootKernel}" ]]; then
    echo "Reboot" >&2
    exit 1
fi
exit 0
