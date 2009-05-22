#!/bin/bash
#
# run function to check exit codes
#
# *** NOTICE ***
# This function DOES NOT WORK when using stdin/stdout/stderr
#
# For example:
#    run gzip -c /home/user/filename.ext > /tmp/filename.ext
#
# The above example will fail. 
#
# v.22 - Added catch for cd (and able to add later as needed)
# v.21 - Only call echo if non-null response
# v.2  - Added 127 code support
#      - Added a few more comments
# v.1  - Initial Script
#
# Copyright (C) 2008  James Bair <james.d.bair@gmail.com>
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

run() {
	# Assign our variables based on our input.
	# Application
	app="$1"
	# Command
	com="$@"
	# Execute Command
	exc=$($@ 2>&1)
	# Exit Code
	ec=$(echo $?)

	# Catch any bad commands and print out why it's not good.
	case $app in
		# cd built-in doesn't work with this function
		cd)
		echo "ERROR: $app is not supported by run()" >&2
		echo "Exiting." >&2
		exit 1
		;;

		# Everything else is fine, proceed.
		*)
		;;
	esac

	# Check our exit code and respond accordingly. 
	# Simply echo the output if we exit cleanly.
	if [ $ec -eq 0 ]; then
		if [ -n "$exc" ]; then
			echo "$exc"
		fi
	# Checks for the application not being found in our $PATH by BASH.
	elif [ $ec -eq 127 ]; then
		echo -e "ERROR: The following application was not found by BASH:\n\n${app}\n\nThis application was called when trying to run the following command:\n\n${com}\n\nExiting."
		exit $ec
	# Anything else would be a non-specific exit code. Print our info and exit.
	else
		echo -e "ERROR: We received an exit code of $ec when running the following command:\n\n${com}\n\nError message given:\n\n${exc}\n\nExiting."
		exit $ec
	fi
}
