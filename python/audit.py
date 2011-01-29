#!/usr/bin/python -tt
# A script to audit a Gentoo server for all pertinent information.

import commands
import glob
import os
import socket
import sys

# Where we save out output to
logFile = '%s.output.txt' % (socket.gethostname(),)

# The system commands we run
ourCommands = ( 'w',
                'emerge --info',
                'emerge -ep world',
                'df -h',
                'free -m',
                'mount',
                'uname -a',
                'rc-update -s' )

# File we read from /etc/
etcFiles = ( 'fstab',
             'group',
             'make.conf',
             'passwd' )

# Modules to ignore from eselect
badMods = ( 'help', 'usage', 'version', 'all', '')

def log(input, logFile):
    """
    Write to stdout and to file at the same time.
    """

    sys.stdout.write(input)
    sys.stdout.flush()
    f = open(logFile, 'a')
    f.write(input)
    f.close()

def comWrapper(command, logFile):
    """
    Wraps our commands with text using the log() function.
    """

    lb = '#########################################################'
    log("Running command: %s\n" % (command,), logFile)
    log("%s\n\n" % (lb,), logFile)
    log(commands.getoutput(command), logFile)
    log("\n%s\n\n\n" % (lb,), logFile)

def main(logFile):
    """
    Main function for audit.py
    """

    # Run each command in our list
    for command in ourCommands:
        comWrapper(command, logFile)

    # cat each file in etcFiles. Need to migrate to using f.open()
    # but I want the output wrapper the same as with commands.
    for item in etcFiles:
        comWrapper('cat /etc/%s' % (item,), logFile)

    # Find the users in the cron group
    for line in file('/etc/group', 'r').readlines():
        if 'cron:x:' in line:
            # Remove the newline, grab the users and
            # break them into an array.
            line = line.strip()
            usersData = line.split(':')[-1]
            users = usersData.split(',')
            break

    # Print out their crontab if applicable
    for user in users:
        comWrapper('crontab -l -u %s' % (user,),logFile)

    # Find all our file based cron entries
    cronItems = glob.glob('/etc/cron*')
    for item in cronItems:
        # If it's a file, print it's contents
        if os.path.isfile(item):
            comWrapper('cat %s' % (item,), logFile)
        # If it's a directory, dig in deeper and find the files
        elif os.path.isdir(item):
            cronFiles = os.listdir(item)
            for ourFile in cronFiles:
	        # Add the path to the file.
                ourFile = '%s/%s' % (item, ourFile)
		# Ignore .keep files
                if '.keep' in ourFile:
                    continue
		# If a file, do the deed.
                if os.path.isfile(ourFile):
                    comWrapper('cat %s' % (ourFile,), logFile)

    # Find our eselect modules and list their info
    esData = commands.getoutput('eselect modules list')
    esList = esData.split('\n')
    for line in esList:

        if ':' in line or line == '':
            continue

        mod = line.split()[0]

        if mod in badMods:
            continue

        # Remove lines we do not need
        comWrapper('eselect %s list' % (mod,), logFile)


# Main
if __name__ == '__main__':
    if not os.path.isfile(logFile):
        main(logFile)
        sys.exit(0)
    else:
        sys.stderr.write('%s already exists.\n' % (logFile,))
        sys.exit(1)
