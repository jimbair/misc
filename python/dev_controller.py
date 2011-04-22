#!/usr/bin/python
# List what controllers your /dev/sdX or /dev/hdX devices are
# attached to in Linux operating systems.
# Doesn't support anything cool like SAN yet. Just local storage.

import commands
import glob
import os
import sys

def findDeviceController(device):
    """
    Takes a given device and
    """
    devLink = '/sys/block/' + device.split('/')[-1]

    if not os.path.islink(devLink):
        return False

    # Have fun looking at this one, lol
    rawInfo = os.path.realpath(devLink)
    old = None
    for item in rawInfo.split('/'):
        if old is None:
            old = item
            continue

        if 'host' in item:
            break

        old = item

    pciCode = ':'.join(old.split(':')[1:])

    # Now find the matching device to the PCI code
    status, out = commands.getstatusoutput('lspci')
    if status != 0:
        msg = "Error: Unable to execute command 'lspci'\n"
        sys.stderr.write(msg)
        sys.exit(1)

    for line in out.split('\n'):
        if pciCode in line:
            return line.split(':')[2].strip()

    # Something went wrong and our PCI code is invalid
    return None

def main():

    devPrefix = '/dev/'

    if sys.platform != 'linux2':
        msg = 'Error: This platform is unsupported.\n'
        msg += 'Supported platforms: Linux\n'
        sys.stderr.write(msg)
        sys.exit(1)

    devices = glob.glob(devPrefix + '[s|h]d[a-z]')

    if devices == []:
        msg = 'Error: No block devices found.\n'
        sys.stderr.write(msg)
        sys.exit(1)

    devices.sort()

    msg = "The following devices and their controllers were found:\n\n"
    sys.stdout.write(msg)

    for device in devices:
        controller = findDeviceController(device)
        msg = "%s is connected to %s\n" % (device, controller)
        sys.stdout.write(msg)

    sys.exit(0)

if __name__ == '__main__':
    main()
