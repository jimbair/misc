#!/usr/bin/python -tt
# Script to pull in the monitoring IPs
# and save them as a list in Python.
# Just example code for now. Need to tie
# into fail2ban and denyhosts for exlcusions.

import sys
import urllib2

def cloudkick_ips():
    """
    Function to fetch the list of IPs used
    to monitor CloudKick clients and return
    them as a list.
    """

    # Wrap in a try/except in case
    try:
        # Open connection and read the lines, then string them together.
        ourURL = 'https://api.cloudkick.com/1.0/monitor_ips'
        connection = urllib2.urlopen(ourURL)
        lineList = connection.readlines()
        string = ''.join(lineList)
        ourList = eval(string)
    except:
        ourList = None

    return ourList

# Main
if __name__ == '__main__':
    ips = cloudkick_ips()
    if ips is None:
        sys.stderr.write('Unable to find our CloudKick IPs.\n')
        sys.exit(1)
    else:
        print '\n'.join(ips)
        sys.exit(0)
