#!/bin/bash
# A basic shell script to rsync sync servers onto our NAS
# Nothing wild, mostly started with excludes from Arch's wiki and added a few
# that met my needs. Assumes passwordless keypairs as well as the ~/.ssh/config 
# files exist. This could be cleaned up a bit to be more robust. My main use 
# case is to backup cloud servers. Dynamically reads the SSH config and runs 
# rsync across all hosts.
#
# v0.12
# Jim Bair

failures=0

for host in $(awk '$1=="host" {print $2}' ~/.ssh/config); do
  date
  echo "Running backup for ${host}"
  rsync -ave ssh --no-perms --no-owner --no-group --delete-excluded --exclude={"/dev/*","/proc/*","/swapfile","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/mirrors/*","/usr/src/linux*","/usr/portage/*","/var/lib/transmission/Downloads/*","/snap/*","/var/lib/plexmediaserver/*","/var/lib/lxcfs/*","/lost+found"} ${host}:/ /volume1/storage/Jim/Backups/servers/${host}
  ec=$?
  echo "Backup for ${host} exit code: ${ec}"
  echo
  [[ "${ec}" -ne 0 ]] && failures=$((failures+1))
done

date
exit ${failures}
