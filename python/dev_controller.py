#!/usr/bin/python
# List what controllers your /dev/sdX or /dev/hdX devices are
# attached to in Linux operating systems.
# Doesn't support anything cool like SAN yet. Just local storage.
# Only tested on Debian based systems currently (Ubuntu).

import commands
import glob
import os
import stat
import sys

def findDeviceController(device):
    """
    Takes a given block device and returns the controller it's attached to.
    Depends on lspci being installed on the system.
    """

    # Debian
    if os.path.isfile('/etc/debian_version'):
        devLink = '/sys/block/' + device.split('/')[-1]
    # Red Hat
    elif os.path.isfile('/etc/redhat-release'):
        devLink = '/sys/block/%s/device' % (device.split('/')[-1],)
    # Everything else
    else:
        msg = 'Error: Unsupported Linux platform.\n'
        sys.stderr.write(msg)
        sys.exit(1)

    # Make sure our dev symlink is a symlink
    if not os.path.islink(devLink):
        return False

    # Find where our symlink points to
    rawInfo = os.path.realpath(devLink)

    # Find the last controller. The last controller is the last entry
    # found before the host[0-9] entry, split by slashes.
    last = None
    for item in rawInfo.split('/'):
        # Set our value first.
        if last is None:
            last = item
            continue

        # If we are on the host, our last item was the winner.
        if 'host' in item:
            break

        # If we are here, we haven't hit the host yet.
        last = item

    # Essentially strip off the first 0's of our string.
    pciCode = ':'.join(last.split(':')[1:])

    # Find our devices/PCI codes
    status, out = commands.getstatusoutput('lspci')
    if status != 0:
        msg = "Error: Unable to execute command 'lspci'\n"
        sys.stderr.write(msg)
        sys.exit(1)

    # Now find the matching device to the PCI code.
    for line in out.split('\n'):
        if pciCode in line:
            return line.split(':')[2].strip()

    # Something went wrong and our PCI code is invalid.
    return None

def findBlockDevices():
    """
    Search the local filesystem for known block devices.
    Supports: /dev/sdX, /dev/hdX, /dev/cssis/cXdY
    """

    # Find our block devices. Returns [] if none.
    results = glob.glob('/dev/[s|h]d[a-z]')

    # HP Server Block Devices
    hpDevices = glob.glob('/dev/cciss/c[0-9]d[0-9]')

    # If we found any devices, add them in.
    if hpDevices != []:
        results = results + hpDevices

    # If we found nothing, return None
    if results == []:
        return None

    return results

def main():
    """
    Our main function for dev_controller.py
    """

    # Only supported on Linux.
    if sys.platform != 'linux2':
        msg = 'Error: This platform is unsupported.\n'
        msg += 'Supported platforms: Linux\n'
        sys.stderr.write(msg)
        sys.exit(1)

    # Find our block devices.
    devices = findBlockDevices()

    # Make sure we found something.
    if devices is None:
        msg = 'Error: No block devices found.\n'
        sys.stderr.write(msg)
        sys.exit(1)

    # Make sure we find block devices.
    for device in devices:
        mode = os.stat(device)[stat.ST_MODE]
        if not stat.S_ISBLK(mode):
            devices.remove(device)

    # Sort our devices alphabetically.
    devices.sort()

    # Print out our results. Should handle findDeviceController()
    # errors better since now it prints errors in the results.
    msg = "The following devices and their controllers were found:\n\n"
    sys.stdout.write(msg)

    for device in devices:
        controller = findDeviceController(device)
        msg = "%s is connected to %s\n" % (device, controller)
        sys.stdout.write(msg)

    sys.exit(0)

# Main
if __name__ == '__main__':
    main()
