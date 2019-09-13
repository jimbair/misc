#!/bin/bash
# A simple script to find the max speed of your boosting CPU
MAX=$(grep MHz /proc/cpuinfo | sort -n | tail -1 | cut -d ' ' -f 3 | cut -d . -f 1)
while true; do
  CURRENT=$(grep MHz /proc/cpuinfo | sort -n | tail -1 | cut -d ' ' -f 3 | cut -d . -f 1)
  [[ ${CURRENT} -gt ${MAX} ]] && MAX=${CURRENT}
  echo "Current: ${CURRENT} Max: ${MAX}"
  sleep 0.2
done
