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
  dest="${backupdir}/${host}"
  echo "Backing up ${host} to ${dest}"
  [[ -d "${dest}" ]] || mkdir -p ${dest}
  if [ $? -ne 0 ]; then
    echo "Creating the missing ${dest} failed. Exiting"
	exit 1
  fi

  echo "Running backup for ${host}"
  rsync -ave ssh --no-perms --no-owner --no-group --delete-excluded --exclude={"/dev/*","/proc/*","/swapfile","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/mirrors/*","/usr/src/linux*","/usr/portage/*","/var/lib/transmission-daemon/downloads/*","/var/lib/transmission/Downloads/*","/snap/*","/home/danny/*","/home/jim/.local/share/Steam/*","/home/jim/.cache/*","/home/jim/Downloads/*","/var/lib/plexmediaserver/*","/var/lib/lxcfs/*","/lost+found","/var/db/repos/*","/var/lib/docker/*"} ${host}:/ ${dest}
  ec=$?

  echo -e "Backup for ${host} exit code: ${ec}\n"

  # If SSH fails to connect and it's not a server, then move along
  if [ ${ec} -eq 255 ]; then
    grep -q ${host} <<< ${intermittent} && continue
  fi

  [[ "${ec}" -ne 0 ]] && failures=$((failures+1))

done

date
exit ${failures}
