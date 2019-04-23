#!/usr/bin/python -tt
# Small python program used to check if a list of given domains
# has any domains available for registration. Best used in cron
# to check daily for any new domains availabe to register.
#
# Probably only useful to me, but hey, why not share.
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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

import commands
import os
import sys

def usage():
    """
    Our usage function.
    """
    prog = os.path.basename(__file__)
    msg = "Usage: %s domain1 domain2 ..\n" % (prog,)
    sys.stderr.write(msg)
    sys.exit(1)

def domainInfo(domain):
    """
    Pull our whois info for a given domain.
    """

    whois = "whois %s" % (domain,)
    status, out = commands.getstatusoutput(whois)
    if status == 0:
        return out
    else:
        msg = "Error: Unable to fetch information "
        msg += "for the domain '%s'\n" % (domain,)
        sys.stderr.write(msg)
        sys.exit(1)

def expirDomainCheck(domain):
    """
    Validates if a domain is free based on
    the expiration date. Fairly common for
    a lot of TLDs. .com/.net/.org all work
    with this.
    """
    info = domainInfo(domain)

    # If this exists, domain should be taken
    if 'Expir' in info:
        return False
    # If we never find our line, it should be available
    else:
        return True


def domainAvailable(domain, tld):
    """
    Checks if a given domain is available.
    """

    expirList = ( 'com', 'net', 'org', 'info', 'biz', 'us', 'ca',
                  'mobi', 'me', 'tv', 'cc', 'ws', 'asia' )
    result = None

    if tld in expirList:
        result = expirDomainCheck(domain)
    else:
        msg = "Unsupported TLD type '.%s' " % (tld,)
        msg += "for domain '%s'.\n" % (domain,)
        sys.stderr.write(msg)
        sys.exit(1)

    return result

def main():
    """
    Our main function.
    """

    msg = None
    domains = sys.argv[1:]

    # Validate first.
    if len(domains) < 1:
        usage()

    for domain in domains:
        if '.' not in domain:
            usage()

    # Now, actually do some work
    for domain in domains:
        tld = domain.split('.')[-1]

        if domainAvailable(domain, tld):
            msg = "The domain '%s' is available!\n" % (domain,)
            sys.stdout.write(msg)

    if msg is None:
        msg = "No domains are available at this time.\n"
        sys.stdout.write(msg)

    sys.exit(0)

if __name__ == '__main__':
    main()
