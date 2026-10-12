import plistlib
import tempfile
import unittest
from pathlib import Path
from configure_http import configure

class HTTPConfigurationTests(unittest.TestCase):
    def test_replaces_obsolete_host_settings_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Info.plist'
            path.write_bytes(plistlib.dumps({'CFBundleDisplayName': 'Ant Streams', 'NSAppTransportSecurity': {'NSExceptionDomains': {'old.example.invalid': {}}}}))
            configure(path)
            first = path.read_bytes()
            configure(path)
            self.assertEqual(path.read_bytes(), first)
            values = plistlib.loads(first)
            self.assertEqual(values['NSAppTransportSecurity'], {'NSAllowsArbitraryLoads': True})
            self.assertEqual(values['CFBundleDisplayName'], 'Ant Streams')
            self.assertNotIn(b'old.example.invalid', first)

if __name__ == '__main__':
    unittest.main()
