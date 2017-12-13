#!/bin/bash
# A basic shell script to rsync sync servers onto our NAS
# Nothing wild, mostly started with excludes from Arch's wiki and added a few
# that met my needs. Assumes passwordless keypairs as well as the ~/.ssh/config 
# files exist. This could be cleaned up a bit to be more robust. My main use 
# case is to backup cloud servers. Dynamically reads the SSH config and runs 
# rsync across all hosts.
#
# v0.1
# Jim Bair

for host in $(awk '$1=="host" {print $2}' ~/.ssh/config); do
  rsync -ave ssh --delete-excluded --exclude={"/dev/*","/proc/*","/swapfile","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/mirrors/*","/usr/src/linux**","/usr/portage/*","/var/lib/transmission/Downloads/*","/lost+found"} ${host}:/ /volume1/storage/Jim/Backups/${host}
done
