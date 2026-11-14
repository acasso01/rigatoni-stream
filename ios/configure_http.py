#!/usr/bin/env python3
"""Set direct HTTP IPTV support in a local, generated iOS Info.plist.

Providers are configured at runtime, so per-domain ATS exceptions cannot cover them.
No server hostname, provider credential or account token is embedded in the build.
"""
import argparse
import os
from pathlib import Path
import plistlib


def configure(plist_path):
    path = Path(plist_path)
    with path.open("rb") as handle:
        values = plistlib.load(handle)
    # Remove obsolete per-host exceptions. Domains listed in NSExceptionDomains
    # otherwise override the global allowance, including when the exception is empty.
    values["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
    with path.open("wb") as handle:
        plistlib.dump(values, handle)
    os.chmod(path, 0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", default="Generated/Info.plist")
    args = parser.parse_args()
    configure(args.plist)
    print("Direct HTTP IPTV access configured (app-wide ATS exception).")


if __name__ == "__main__":
    main()
