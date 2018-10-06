#!/bin/bash
# Check if CentOS/Ubuntu needs a reboot to apply the latest kernel update
liveKernel=$(uname -r)
bootKernel=$(ls -t /boot/vmlinuz* | grep -v rescue | head -n 1 | cut -d \- -f 2-)
if [[ "${liveKernel}" != "${bootKernel}" ]]; then
    echo "Reboot" >&2
    exit 1
fi
exit 0
