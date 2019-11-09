#!/bin/bash
# A shell script to rsync sync servers onto our NAS
#
# Nothing wild, it started with excludes from the Arch wiki and I added a few
# that met our needs. It assumes passwordless keypairs as well as the ~/.ssh/config
# files exist. Dynamically reads the SSH config and runs rsync across all hosts.
#
# v0.2
# Jim Bair

# For laptops, desktops; anything that's not up all the time
intermittent='desktop laptop'

# Catch failures from servers that should be up all the time
failures=0

for host in $(awk '$1=="host" {print $2}' ~/.ssh/config); do
  date
  echo "Running backup for ${host}"
  rsync -ave ssh --no-perms --no-owner --no-group --delete-excluded --exclude={"/dev/*","/proc/*","/swapfile","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/mirrors/*","/usr/src/linux*","/usr/portage/*","/var/lib/transmission-daemon/downloads/*","/var/lib/transmission/Downloads/*","/snap/*","/var/lib/plexmediaserver/*","/var/lib/lxcfs/*","/lost+found"} ${host}:/ /volume1/storage/Jim/Backups/servers/${host}
  ec=$?
  echo "Backup for ${host} exit code: ${ec}"
  echo
  echo ${intermittent} | grep -q ${host} && continue
  [[ "${ec}" -ne 0 ]] && failures=$((failures+1))
done

date
exit ${failures}
