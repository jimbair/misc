#!/bin/bash
#
# Script to automate the deployment of folding@home
# onto a Linux system running either Red Hat or Debian.
# Supports Ubuntu as well, assuming Fedora as well.
# Credits go here as well:
# http://tinyurl.com/yr8w8m
#
# Set to work with version 6.02 of Folding@Home for Linux
#
# v0.21 - A few syntax changes
#       - Tabs now spaces
# v0.2  - Confirmed Working - Needs More Testing
# v0.1  - Testing/Creation
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

# Assign your username and team here. Feel free to use mine! :D
user='tsuehpsyde'
team='75581'
# Used to get mega point units. You can set to normal/no if you want.
unitsize='big'
advmethods='yes'
# Added since Folding doesn't always see this somehow.
ramsize=$(free -m | awk '( $1 ~ /Mem:/ ) { print $2 }')

# Timestamp our echos
echostamp() {
    echo -e "[$(date)] - $@"
}

# Stuff commands into our screen.
# Note the ^M after $@. This is a newline created by ctrl+V, ctrl+M.
# This will break formatting when the file is opened outside of vim.
stuffit() {
    screen -p 0 -X -S foldingsetup stuff "${@}" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echostamp "Sent command '$@' into our screen"
        # Sleep here to slow down the sequential stuffs
        pause 1
    else
        echostamp "ERROR: Our screen is not present. Exiting." >&2
        exit 1
    fi
}

# Make our pauses more pretty. =)
pause() {
    # Make sure we got proper input
    if [ -z "$1" ] || [ -n "$2" ]; then
        echo 'ERROR: Must be called with one numerical variable.' >&2
        exit 1
    fi

    # Declare our variable
    num=$1

    # Ensure we got a number
    numcheck=$(echo $num | sed '/[^0-9]/d')
    if [ -z "$numcheck" ]; then
        echo 'ERROR: Our numerical variable *MUST* be an integer (e.g. 1, 7, 15, etc.)' >&2
        echo 'Exiting.' >&2
        exit 1
    # If we have a number, let's do the deed
    else
        echo -n "[$(date)] - Pausing for $numcheck seconds"
        # Print a period and increment down one, go until zero
        while [ "$numcheck" -gt 0 ]; do
            # Print with a newline if our last period
            sleep 1
            if [ "$numcheck" -ne 1 ]; then
                echo -n .
            else
                echo .
            fi
            numcheck=$(($numcheck - 1))
        done
    fi
}

# Must be root to run this script
if [ $UID -ne 0 ]; then
    echostamp 'ERROR: You must be root to run this script. Exiting.' >&2
    exit 1
# Exit if arguments are passed since we don't need any.
elif [ $# -ne 0 ]; then
    echostamp 'ERROR: This script requires no arguments. Exiting.' >&2
    exit 1
# In case $ramsize fails to get generated
elif [ -z "$ramsize" ]; then
    echostamp 'ERROR: Unable to find our system memory size. Exiting.' >&2
fi

# Find which OS we are installing on
if [ -s /etc/redhat-release ]; then
    echostamp 'Red Hat based OS detected.'
    OS='rh'
elif [ -s /etc/debian_version ]; then
    echostamp 'Debian based OS detected.'
    OS='deb'
else
    echostamp 'This OS is not supported by this script. Exiting.' >&2
    exit 1
fi

# Create our user and home directory
echo -n "[$(date)] - Creating folding user and directory..."
# Add user if needed
if [ -z "$(grep /var/folding /etc/passwd)" ]; then
    useradd -d /var/folding -r folding
fi
# Create directory if needed
if [ ! -d /var/folding ]; then
    mkdir /var/folding
    chown folding.folding /var/folding
fi
echo 'done.'

# Download our script - Not mirrored locally since it gets updated by author
echo -n "[$(date)] - Downloading finstall..."
cd /var/folding
wget -c http://www.vendomar.ee/~ivo/finstall > /dev/null 2>&1
# Check to see if our download failed
if [ $? -ne 0 ]; then
    echostamp 'ERROR: The download of the finstall failed. Exiting.'
    exit 1
else
    echo 'done!'
fi

# Begin setup of screen for script that requires interactive responses
echo -n "[$(date)] - Creating a screen to automate the setup process..."
screen -dm foldingsetup
# Ensure our screen started up properly
if [ $? -ne 0 ]; then
    # Put our timestamp on a newline
    echo
    echostamp 'ERROR: Unable to create our screen session. Exiting.'
    exit 1
else
    echo 'done!'
fi

# Login as folding and run script
stuffit "su - folding"
stuffit "/bin/bash ./finstall"
pause 10

# Answer our script
# Might need pauses, be sure to test

# Answer finstall questions

# Do You want to read finstall FAQ (y/n)?: 
stuffit "n"
pause 10

# Is this the correct MD5SUM value
stuffit "y"

# Do You want to use any of these 3rd party FAH utilities (y/n)?: 
stuffit "n"
pause 5

# Do You want to use automatic MachineID changing (y/n)?:
stuffit "y"
pause 10

# Answer the Folding@Home configuration questions
# User name [Anonymous]? 
stuffit "$user"

# Team Number [0]? 
stuffit "$team"

# Passkey []? 
stuffit ""

# Ask before fetching/sending work (no/yes) [no]? 
stuffit ""

# Use proxy (yes/no) [no]? 
stuffit ""

# Acceptable size of work assignment...
stuffit "$unitsize"

# Change advanced options (yes/no) [no]?
stuffit "yes"

# Core Priority (idle/low) [idle]?    
stuffit ""

# Disable highly optimized assembly code (no/yes) [no]? 
stuffit ""

# Interval, in minutes, between checkpoints (3-30) [15]? 
stuffit ""

# Memory, in MB, to indicate?
stuffit "$ramsize"

# Set -advmethods flag always, requesting new advanced scientific cores...
stuffit "$advmethods"

# Ignore any deadline information (clock errors)...
stuffit ""

# Machine ID (1-16) [1]? 
stuffit ""
pause 10

# Do You want to use it for this client and for all remaining...
stuffit "y"
pause 60

# Skip past the :more section after installer finishes
# Don't need the ^M newline, but easier to pass it anyway.
stuffit "  "

# Our screen should no longer be needed
# Exit out of the user folding
stuffit "exit"
# Exit out of root
stuffit "exit"


# Setup init stuff
echostamp "Beginning service configuration."
cp foldingathome/folding /etc/init.d/
chmod 4775 foldingathome/folding

# Setup start @ boot and start service based on OS
if [ "$OS" == 'rh' ]; then
    chkconfig folding on
    pause 5
    service folding start
elif [ "$OS" = 'deb' ]; then
    update-rc.d folding defaults
    pause 5
    /etc/init.d/folding start
else
    echostamp 'ERROR: How did we get here? Please investigate.' >&2
    exit 1
fi

echostamp 'Service configuration has been completed!'

# All done
echostamp 'Setup has been completed!'
exit 0
