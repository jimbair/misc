# Fixes e1000e continuously resetting
# Lock to a kernel version to test new updates
# 
# v.02 - May 2nd, 2020
# Jim Bair

# root's crontab only has /bin and /usr/bin in RHEL 8.2.0
PATH='/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin'

# Blacklisting current kernel known to have the bug
kernel_release='4.18.0-193.1.2.el8_2.x86_64'
gateway_dev=$(ip r | grep ^default | cut -d ' ' -f 5)

# Make sure we're root, we found our gw device, and disable the bad bits
# https://serverfault.com/questions/616485/e1000e-reset-adapter-unexpectedly-detected-hardware-unit-hang
[[ "$UID" == 0 ]] || exit 1
[[ -n "${gateway_dev}" ]] || exit 2
[[ $(uname -r) == "${kernel_release}" ]] && ethtool -K ${gateway_dev} gso off gro off tso off
