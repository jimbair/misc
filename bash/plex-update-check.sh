#!/bin/bash
# plex-update-check.sh
# A simple script to alert me if I need to update plex on our nas

# Can also be extracted locally but the api validates that our service is up
INSTALLED=$(curl -s "http://localhost:32400/identity" | grep -oP \
  '<MediaContainer[^>]+version="\K[^"]+')
if [[ -z "${INSTALLED}" ]]; then
  echo "Could not read installed Plex version from local API."
  exit 1
fi

# No auth required which is nice
API_JSON=$(curl -s "https://plex.tv/api/downloads/5.json")

LATEST=$(echo "${API_JSON}" | jq -r \
  ".nas[\"Synology (DSM 7)\"].version // .nas.Synology.version" 2>/dev/null)
if [[ -z "${LATEST}" ]]; then
  echo "Could not read latest version from Plex API."
  exit 1
fi

# Alert if needed
if [[ "${INSTALLED}" != "${LATEST}" ]]; then
  echo "Update available"
  echo "Installed: ${INSTALLED}"
  echo "Latest:    ${LATEST}"
  exit 1
fi

# All done
exit 0
