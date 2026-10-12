#!/usr/bin/env python3
"""Enable user-entered HTTP providers in a generated native app. No provider data is read."""
import argparse
from pathlib import Path
import plistlib


def configure(plist_path):
    path = Path(plist_path)
    with path.open('rb') as handle:
        values = plistlib.load(handle)
    # Unknown user-entered hosts require broad ATS access. HTTPS trust remains enforced.
    # Do not add finer-grained ATS keys: those override this key on modern Apple OSes.
    values['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads': True}
    with path.open('wb') as handle:
        plistlib.dump(values, handle)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plist', default='Generated/Info.plist')
    configure(parser.parse_args().plist)
    print('Standalone HTTP/HTTPS provider support configured. No provider hostname is embedded.')
