"""Packaging security contracts (stdlib unittest; no Xcode required)."""
import importlib.util
from pathlib import Path
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'macOS/scripts'))
spec = importlib.util.spec_from_file_location('hermex_build', ROOT / 'macOS/scripts/build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class UpdatePackagingTests(unittest.TestCase):
    def test_update_configuration_requires_https_feed_and_real_public_key(self):
        valid = {'feedURL': 'https://github.com/KenMercusLai/hermex-mac/releases/latest/download/appcast.xml',
                 'publicEDKey': 'ZGKYOJFq64vV2b/pVsWRMfY+crWyV8PWy1l/xMKK0Xg='}
        info = build.update_info(valid)
        self.assertEqual(info['SUFeedURL'], valid['feedURL'])
        self.assertEqual(info['SUPublicEDKey'], valid['publicEDKey'])
        self.assertTrue(info['SUEnableAutomaticChecks'])
        self.assertTrue(info['SUAutomaticallyUpdate'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertEqual(info['SUSignedFeedFailureExpirationInterval'], 0)
        for invalid in ({}, dict(valid, feedURL='http://example.com/appcast.xml'),
                        dict(valid, publicEDKey='REPLACE_ME'), dict(valid, publicEDKey='')):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                build.update_info(invalid)


    def test_adhoc_distribution_requires_explicit_library_validation_consent(self):
        with self.assertRaises(ValueError):
            build.signing_entitlements('-', False)
        self.assertEqual(build.signing_entitlements('Developer ID Application: Example', False), {})
        self.assertEqual(build.signing_entitlements('-', True),
                         {'com.apple.security.cs.disable-library-validation': True})

    def test_pinned_sdk_rejects_tampering_before_extracting(self):
        import sys
        sys.path.insert(0, str(ROOT / 'macOS/scripts'))
        import sparkle_sdk
        with self.assertRaises(ValueError):
            sparkle_sdk.verify_archive(b'not the pinned official archive')


if __name__ == '__main__':
    unittest.main()
