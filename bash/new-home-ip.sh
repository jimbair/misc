#!/bin/bash
# Script to update our home IP address on a remote server
# at the firewall as well as config level as required.
# Hacked together angrily on a Sunday - fairly messy :P 

ipv4=$(host tsue.net | grep 'has address' | awk '{print $NF}')
ipv6=$(host tsue.net | grep 'has IPv6 address' | awk '{print $NF}' | cut -d ':' -f -4)
if [[ -z "${ipv4}" ]] || [[ -z "${ipv6}" ]]; then
  echo "ERROR: New IP information is missing. Exiting." >&2
  exit 1
fi

old4=$(iptables -L -n | grep '81' | awk '{print $4}')
old6=$(ip6tables -L -n | grep '81' | awk '{print $3}' | cut -d ':' -f -4)
if [[ -z "${old4}" ]] || [[ -z "${old6}" ]]; then
  echo "ERROR: Old IP information is missing. Exiting." >&2
  exit 1
fi

if [[ "${ipv4}" == "${old4}" ]] && [[ "${ipv6}" == "${old6}" ]]; then
  echo "INFO: All IP information is up-to-date"
  exit 0
fi

################
# IPv4 Section #
################

if [[ "${ipv4}" != "${old4}" ]]; then

  temp=$(mktemp)
  [[ $? -ne 0 ]] && echo "ERROR: mktemp is missing" && exit 2

  iptables-save > ${temp}
  sed -i "s/${old4}/${ipv4}/" ${temp}
  iptables-restore < ${temp}
  [[ $? -ne 0 ]] && echo "ERROR: iptables-restore failed" && exit 3
  rm -f ${temp}

  # TODO - Test transmission fix
  # Note that whitelisting ipv6 is not supported
  transConf='/var/lib/transmission/.config/transmission-daemon/settings.json'
  grep -q ${old4} ${transConf}
  if [[ $? -eq 0 ]]; then
    systemctl stop transmission-daemon
    sed -i "s/${old4}/${ipv4}/" ${transConf}
    [[ $? -ne 0 ]] && echo "ERROR: transmission update failed" && exit 4
    systemctl start transmission-daemon
fi


################
# IPv6 Section #
################

if [[ "${ipv6}" != "${old6}" ]]; then

  temp=$(mktemp)
  [[ $? -ne 0 ]] && echo "ERROR: mktemp is missing" && exit 2

  ip6tables-save > ${temp}
  sed -i "s/${old6}/${ipv6}/" ${temp}
  ip6tables-restore < ${temp}
  [[ $? -ne 0 ]] && echo "ERROR: iptables-restore failed" && exit 3
  rm -f ${temp}

fi

exit 0
