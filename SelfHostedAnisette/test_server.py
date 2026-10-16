import base64
import json
import tempfile
import unittest
from pathlib import Path
import server

class BlobBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = server.ADI_DIR
        server.ADI_DIR = Path(self.directory.name)
        self.identifier = base64.b64encode(bytes(range(16))).decode()

    def tearDown(self):
        server.ADI_DIR = self.previous
        self.directory.cleanup()

    def encoded(self, files, identifier=None):
        return base64.b64encode(json.dumps({'version': 1, 'identifier': identifier or self.identifier, 'files': files}).encode()).decode()

    def test_blob_round_trip_is_bound_to_the_clients_identifier(self):
        (server.ADI_DIR / 'adi.pb').write_bytes(b'fixture-device-data')
        blob = server.export_blob(self.identifier)
        server.clear_blob()
        server.import_blob(self.identifier, blob)
        self.assertEqual((server.ADI_DIR / 'adi.pb').read_bytes(), b'fixture-device-data')
        other = base64.b64encode(b'x' * 16).decode()
        with self.assertRaises(ValueError):
            server.import_blob(other, blob)

    def test_untrusted_blob_cannot_write_outside_adi_directory(self):
        for name in ('../escape', '/tmp/escape', '..', 'nested/file', 'C:\\escape'):
            with self.assertRaises(ValueError):
                server.import_blob(self.identifier, self.encoded({name: 'eA=='}))
        self.assertEqual(list(server.ADI_DIR.iterdir()), [])

    def test_entire_archive_is_validated_before_any_file_is_written(self):
        with self.assertRaises(ValueError):
            server.import_blob(self.identifier, self.encoded({'adi.pb': 'eA==', '../escape': 'eA=='}))
        self.assertEqual(list(server.ADI_DIR.iterdir()), [])

    def test_identifier_is_exactly_sixteen_bytes(self):
        for identifier in ('invalid!', base64.b64encode(b'x' * 15).decode(), base64.b64encode(b'x' * 17).decode()):
            with self.assertRaises(ValueError):
                server.validate_identifier(identifier)

if __name__ == '__main__':
    unittest.main()
