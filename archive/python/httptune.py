#!/usr/bin/python -tt
# A small Python program to check if our Apache installation is misconfigured.
# Currently only checks MaxClients based on Apache's memory footprint per process.
# Will expand as I get suggestions/ideas. This is most definitley a work in progress.
#
# Copyright (C) 2011  James Bair <james.d.bair@gmail.com>
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

import commands
import os
import sys

def checkIfSupported():
    """
    Check if we support our current platform.
    Return True/False
    """

    prog = os.path.basename(__file__)
    supported = True
    supportList = ( 'Red Hat Enterprise Linux Server release 5',
                    'CentOS release 5',
                    'Red Hat Enterprise Linux ES release 4 ' )

    if os.path.isfile('/etc/redhat-release'):
        for item in supportList:
            for line in open('/etc/redhat-release', 'r'):
                if item in line:
                    return True

    msg = "This platform is not supported.\n"
    msg += prog + " supports the following platforms:\n\n"
    msg += '\n'.join(supportList)
    msg += '\n'
    sys.stderr.write(msg)
    sys.exit(1)

def findProcesses():
    """
    Find our system processes
    """

    status, out = commands.getstatusoutput('ps aux')
    if status != 0:
        msg = "ERROR: Unable to find our system processes.\b"
        sys.stderr.write(msg)
        sys.exit(1)

    return out

def findApache(processes):
    """
    Find the number of apache processes on the system currently.
    """

    lines = 0

    for line in processes.split('\n'):
        if '/usr/sbin/httpd' in line:
            lines += 1

    return lines


def findApacheMem(processes):
    """
    Pull out the memory usage from the process list passed
    to us in findProcesses()
    """

    lines, results = [], []

    for line in processes.split('\n'):
        if '/usr/sbin/httpd' not in line:
            continue

        lines.append(line)

    if lines == []:
        return None

    # Build a list of floats with each apache processes'
    # memory footprint
    for line in lines:
        results.append(float(line.split()[3]))

    result = sum(results) / len(results)

    return result

def findPreforkInfo(ourFile):
    """
    Split out the raw data for the prefork.c module from our config.
    """

    found = False
    lines = {}

    if not os.path.isfile(ourFile):
        return None

    for line in open(ourFile, 'r'):

        # Keep skipping until we find our section
        if '<IfModule prefork.c>' not in line and not found:
            continue

        # First time we get here, we found our line
        if '<IfModule prefork.c>' in line and not found:
            found = True
            continue

        # If we've hit the end, abort
        if '</IfModule>' in line and found:
            break

        # Everything else should be useful data in the prefork section
        line = line.strip()
        key, value = line.split()
        lines[key] = int(value)

    if lines == {}:
        return None

    return lines

def findSystemMemory():
    """
    Return the system memory in MB
    """

    for line in open('/proc/meminfo', 'r'):
        if 'MemTotal' not in line:
            continue

        memory = int(line.split()[1]) / 1024
        break

    return memory

def main():

    checkIfSupported()

    processes = findProcesses()

    apacheCount = findApache(processes)
    apacheMemPercent = findApacheMem(processes)
    if apacheMemPercent is None:
        print "Apache is not running or we can't find it's processes."
        sys.exit(1)

    pfInfo = findPreforkInfo('/etc/httpd/conf/httpd.conf')
    ourRAM = findSystemMemory()
    apacheMemAvg = ourRAM * (apacheMemPercent / 100)
    footprint = int(pfInfo['MaxClients'] * apacheMemAvg)
    apacheMem = apacheMemAvg * apacheCount
    suggestedMaxClients = int(ourRAM / apacheMemAvg)

    msg = '\n'
    msg += 'System Configuration:\n'
    msg += 'System RAM: %s MB\n' % (ourRAM,)
    msg += 'Apache MaxClients: %d\n' % (pfInfo['MaxClients'],)
    msg += '\nSystem Info:\n'
    msg += 'Apache Processes: %d\n' % (apacheCount,)
    msg += 'Apache Memory Usage: %d MB (average)\n' % (int(apacheMemAvg))
    msg += 'Apache Current Footprint: %d MB\n' % (apacheMem,)
    msg += 'Apache Maximum Footprint: %d MB\n' % (footprint,)
    msg += 'Suggested MaxClients: %d\n' % (suggestedMaxClients,)
    msg += '\n'
    sys.stdout.write(msg)
    sys.exit(0)

if __name__ == '__main__':
    main()
