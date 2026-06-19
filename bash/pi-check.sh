#!/bin/bash
# Alert if update available for pihole
CMD=$(/usr/local/bin/pihole -up --check-only)
[[ $? -eq 0 ]] || exit 1
[[ -n "${CMD}" ]] || exit 2
grep -q 'update available' <<< ${CMD} && exit 3
exit 0
