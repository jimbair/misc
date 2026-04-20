#!/bin/bash
# A simple script to find the max speed of your boosting CPU
MAX=$(grep MHz /proc/cpuinfo | sort -n | tail -1 | cut -d ' ' -f 3 | cut -d . -f 1)

# Doesn't work on ARM VMs! Good to validate and abort if missing
if [[ -z "${MAX}" ]]; then
  echo "ERROR: Unable to find processor speed. Exiting." >&2
  exit 1
fi

# Do the thang
while true; do
  CURRENT=$(grep MHz /proc/cpuinfo | sort -n | tail -1 | cut -d ' ' -f 3 | cut -d . -f 1)
  [[ ${CURRENT} -gt ${MAX} ]] && MAX=${CURRENT}
  echo "Current: ${CURRENT} Max: ${MAX}"
  sleep 0.2
done
