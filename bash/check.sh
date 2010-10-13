#!/bin/bash
# check.sh - Script to check ports
# Inspired by check.pl from sdavis
#
# Known Issues - Fails on OS X due to netcat being broken on OS X.
#
# Copyright (C) 2010 James Bair <james.d.bair@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

# Ports to check - Change to the ports you'd like to probe
ports='22 3389 80 443 25 21 23794'
script="$(basename $0)"

# Colors are nice.
# http://wiki.archlinux.org/index.php/Color_Bash_Prompt
txtred='\e[0;31m' # Red
txtgrn='\e[0;32m' # Green
txtrst='\e[0m'    # Text Reset

# Exit if given control+c
trap leaveNow 2
leaveNow() {
	echo 'Caught SIGINT. Exiting.'
	exit 1
}

# Validate IPs in function. Credits go here:
# http://www.unix.com/shell-programming-scripting/36144-ip-address-validation-function.html
# Fixed return @ end, cleaned up a bit, removed null check for more precise error responses.
verify_ip() {
	ERROR=0
	# Backup the IFS and change
	oldIFS=$IFS
	IFS=.
	# Won't lie, not 100% sure what the following 2 lines do
	set -f
	set -- $1
	# Make sure we have 4 octets
	if [ $# -eq 4 ]; then
		for seg; do
			case $seg in
				# Checks for numeric chars
				*[!0-9]*)
				ERROR=1
				break
				;;

				# Check for numbers >255
				*) 
				if [ $seg -gt 255 ]; then
					ERROR=2
				fi
				;;
			esac
		done
	else
		# Has more or less than 4 IP segments
		ERROR=3
	fi
	# Revert to the original IRS
	IFS=$oldIFS
	set +f
	# Return our status
	return $ERROR
}

# Input Validation
if [ $# -ne 1 ]; then
	echo "$script - Script to scan commonly used TCP ports." >&2
	echo "usage: $script host" >&2
	exit 1
fi

verify_ip "$1"

# 0 means we got a valid IP
if [ $? -eq 0 ]; then
	echo -e "\nValid IP found! Proceeding with port check."
# 1 means non-numeric OR empty. Run host against it.
elif [ $? -eq 1 ]; then
	echo -e "\nChecking if hostname given is a valid hostname."
	host $1 > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		echo 'ERROR: Invalid IP/Host given. Exiting.' >&2
		exit 1
	else
		echo 'Valid hostname found! Proceeding with port check.'
	fi
else
	echo -e "\nInvalid IP address given! Exiting." >&2
	exit 1
fi

echo -e "\nPassed input validation checks. Checking ports.\n"

# This really needs written using printf since tabs don't always work
for i in $ports; do
	echo -en "  Checking ${1}:${i}"
	nc -z -w 1 $1 $i > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		result="${txtgrn}Open"
	else
		result="${txtred}Closed"
	fi
	echo -e "\t${result}${txtrst}"
done

# All done!
echo -e "\nFinished!\n"
