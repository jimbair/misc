#!/bin/bash
# A shell script to rsync sync servers onto our NAS
#
# Nothing wild, it started with excludes from the Arch wiki and I added a few
# that met our needs. Dynamically reads the SSH config and runs rsync across all
# hosts it finds. Also, pass a server name for a single rsync backup run.
#
# v1.0
# Jim Bair

# For laptops, desktops; anything that's not up all the time
intermittent='desk lenovo'

# Catch failures from servers that should be up all the time
failures=0

# Backups go here
backupdir='/volume1/jim/Backups/servers'

# Do some basic validation
if [[ ! -d "${backupdir}" ]]; then
  echo "ERROR: Backup destination is missing"
  exit 1
elif [[ $# -gt 1 ]]; then
  echo "Usage: $(basename $0) [SERVER]"
  exit 1
elif [[ ! -s ~/.ssh/config ]]; then
  echo "ERROR: SSH config is missing."
  exit 1
elif [[ ! -s 'rsync_excludes.txt' ]]; then
  echo "ERROR: rsync_excludes.txt is missing."
  exit 1
fi

# Does the actual backup work
fetchLatest() {

  host="$1"

  # For server names that break bash
  [[ "${host}" == 'let' ]] && continue

  date

  # Sanity check ssh
  if [[ $(ssh ${host} whoami) != 'root' ]]; then
    echo "ERROR: I was unable to login as root to ${host}"
    return 1
  fi
  
  dest="${backupdir}/${host}"
  echo "Backing up ${host} to ${dest}"
  [[ -d "${dest}" ]] || mkdir -p ${dest}
  if [ $? -ne 0 ]; then
    echo "ERROR: Creating the missing ${dest} failed. Exiting"
    return 1
  fi

  # All of this shellcode just to run rsync?
  echo "Running backup for ${host}"
  rsync -ave ssh --no-perms --no-owner --no-group --delete-excluded --exclude-from 'rsync_excludes.txt' ${host}:/ ${dest}
  ec=$?
  
  echo -e "Backup for ${host} exit code: ${ec}\n"

  # If SSH fails but it's in our intermittent group, then move along
  if [ ${ec} -eq 255 ]; then
    grep -q ${host} <<< ${intermittent} && continue
  fi

  # Catch failures from servers that should be up all the time
  [[ "${ec}" -ne 0 ]] && failures=$((failures+1))

}

# If we have one server, run that
if [[ -n "$1" ]]; then
  fetchLatest $1
# Otherwise, back them all up
else
  for host in $(awk '$1=="host" {print $2}' ~/.ssh/config); do
    fetchLatest ${host}
  done
fi

# All done
date
exit ${failures}
