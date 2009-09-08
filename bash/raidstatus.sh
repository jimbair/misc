#!/bin/bash
# Script to run, via cron, and watch for errors within a
# RAID array using 3ware's tw_cli utility.
#
# If everything is working well, this should never
# give the user output since it runs in cron.
#
# Success = exit 0
# Failure = exit anything else
#
# Failure = email being sent except for tw_cli/sendmail check
#
# This script is written to work for multiple controllers, BUT
# has only been tested in a single controller environment, so
# multi-card users beware.
#
# v1.0 - Re-written, GPL'd and sent to github.
#
# Copyright (C) 2009  James Bair <james.d.bair@gmail.com>
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

PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

fromEmail='RAIDERROR@yourdomain.com'
toEmail='yourname@gmail.com'
raidBinary="/root/bin/tw_cli/tw_cli"

# Make sure tw_cli is present and working
$raidBinary help > /dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "ERROR: The raidBinary file $raidBinary is either missing or not executable. Exiting." >&2
	exit 1
# also test sendmail
else
	sendmail --- > /dev/null 2>&1
	if [ $? -ne 75 ]; then
		echo "ERROR: Sendmail is either not installed or not in the PATH. Exiting." >&2
		exit 1
	fi
fi

# Find our RAID array's controller name, as this changes
controllerName=$($raidBinary info | awk '( $1 ~ /c[0-9]/ ) { print $1 }')

# Verify we got found at least one controller
if [ -z "$controllerName" ]; then
	echo "ERROR: Unable to find our controller name. Exiting." >&2
	exit 2
fi

# Go through each RAID controller found

for i in $controllerName; do

	# Find our RAID status, and if we have a failure, email the entire output of tw_cli to our 'toEmail'
	RAIDstatus=$($raidBinary /${i} show all | awk '$2 ~ /RAID-[0-9]/ { print $3 }')
	# If this is okay, we're done, all is well. Continue to next controller.
	if [ "$RAIDstatus" = "OK" ]; then
		continue
	else
		fullRAID=$($raidBinary /${i} show all)
		# Send the email. This format makes this script ugly but the output to email
		# is more important. Still, I dislike this. =(
		echo -e "subject: Storage Array Has Failed!
!WARNING!

Something is wrong with a RAID array on $(hostname)! Here is the current status of the RAID:

$fullRAID" | sendmail -f $fromEmail $toEmail
		# Verify sendmail worked properly
		if [ $? -eq 0 ]; then
			exit 3
		else
			echo "ERROR: Sendmail failed to send our email. Exiting." >&2
			exit 4
		fi
	fi
done

# IF we get down here, all done!
exit 0
