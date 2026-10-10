import plistlib
import tempfile
import unittest
from pathlib import Path
from configure_http import configure, provider_host


class HTTPConfigurationTests(unittest.TestCase):
    def test_exception_is_exact_and_never_global(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Info.plist'
            path.write_bytes(plistlib.dumps({'CFBundleDisplayName': 'Rigatoni Stream'}))
            configure(path, 'PROVIDER.EXAMPLE.INVALID')
            values = plistlib.loads(path.read_bytes())
            self.assertEqual(values['NSAppTransportSecurity'], {'NSExceptionDomains': {
                'provider.example.invalid': {'NSExceptionAllowsInsecureHTTPLoads': True, 'NSIncludesSubdomains': False}}})
            self.assertEqual(values['CFBundleDisplayName'], 'Rigatoni Stream')
            configure(path, '')
            self.assertNotIn('NSAppTransportSecurity', plistlib.loads(path.read_bytes()))

    def test_rejects_credentials_wildcards_ip_and_account_hosts(self):
        for host in ['http://provider.example.invalid', 'user:password@provider.example.invalid',
                     '*.example.invalid', 'provider.example.invalid:8080', '127.0.0.1',
                     'bad..example.invalid', 'project.supabase.co', 'homepi.test.ts.net']:
            with self.subTest(host=host):
                with self.assertRaises(ValueError):
                    provider_host(host)


if __name__ == '__main__':
    unittest.main()
