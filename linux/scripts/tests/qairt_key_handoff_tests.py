#!/usr/bin/env python3
"""Real OAEP controls cover files, format and redaction; no peer identity, private route or SDK transfer is proved."""

import base64
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(sys.argv.pop(1)).resolve()
SPEC = importlib.util.spec_from_file_location("qairt_handoff", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
HANDOFF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HANDOFF)
PLAIN = b"http://192.0.2.42:9981/preseed"


def encrypt(public: Path, value: bytes, mgf: str = "sha256") -> bytes:
    result = subprocess.run(["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", str(public),
                             "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
                             "-pkeyopt", "rsa_mgf1_md:" + mgf], input=value, capture_output=True, check=True)
    return result.stdout


class HandoffTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="qairt-key-fixture-", dir="/tmp")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.key = cls.root / "original"
        cls.record = HANDOFF.keygen(cls.key)
        cls.other_key = cls.root / "other"
        HANDOFF.keygen(cls.other_key)

    def setUp(self) -> None:
        self.working = tempfile.TemporaryDirectory(prefix="case-", dir=self.root)
        self.addCleanup(self.working.cleanup)
        self.directory = Path(self.working.name) / "key with spaces"
        shutil.copytree(self.key, self.directory)
        self.ciphertext = Path(self.working.name) / "ciphertext.txt"
        self.ciphertext.write_bytes(base64.b64encode(encrypt(self.key / "public.pem", PLAIN)))

    def decrypt(self, fingerprint: str | None = None) -> dict[str, str]:
        return HANDOFF.decrypt(self.directory, self.ciphertext, fingerprint or self.record["sha256_spki"])

    def test_round_trip_and_private_permissions(self) -> None:
        result = self.decrypt()
        self.assertEqual(result["status"], "decrypted-locally")
        self.assertEqual((self.directory / "endpoint.txt").read_bytes(), PLAIN)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        for name in ("private.pem", "public.pem", "public-metadata.json", "endpoint.txt"):
            self.assertEqual((self.directory / name).stat().st_mode & 0o777, 0o600, name)
        self.assertEqual(HANDOFF.inspect(self.directory), self.record)

    def test_failed_crypto_cannot_return_valid_looking_stale_output(self) -> None:
        failed = subprocess.CompletedProcess([], 9, stdout=PLAIN, stderr=PLAIN)
        with patch.object(HANDOFF.subprocess, "run", return_value=failed), self.assertRaises(ValueError) as raised:
            HANDOFF.openssl(["pkeyutl", "-decrypt"])
        self.assertNotIn(PLAIN.decode(), str(raised.exception))

    def test_key_generation_refuses_existing_directory(self) -> None:
        before = (self.directory / "private.pem").read_bytes()
        with self.assertRaises(FileExistsError):
            HANDOFF.keygen(self.directory)
        self.assertEqual((self.directory / "private.pem").read_bytes(), before)

    def test_private_material_is_refused_inside_a_checkout(self) -> None:
        repository = Path(self.working.name) / "repo"
        (repository / ".git").mkdir(parents=True)
        target = repository / "ignored-keys"
        with self.assertRaises(ValueError):
            HANDOFF.keygen(target)
        self.assertFalse(target.exists())

    def test_private_material_cannot_be_a_public_record(self) -> None:
        with patch.object(HANDOFF, "openssl", side_effect=AssertionError("private PEM reached public adapter")), self.assertRaises(ValueError):
            HANDOFF.public_record((self.key / "private.pem").read_bytes())

    def test_rsa_key_size_is_verified_independently(self) -> None:
        private = subprocess.check_output(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"], stderr=subprocess.DEVNULL)
        public = subprocess.check_output(["openssl", "pkey", "-pubout"], input=private)
        with self.assertRaises(ValueError):
            HANDOFF.public_record(public)

    def test_mismatched_public_and_private_keys_are_refused(self) -> None:
        (self.directory / "public.pem").write_bytes((self.other_key / "public.pem").read_bytes())
        with self.assertRaises(ValueError):
            self.decrypt()

    def test_invalid_ciphertext_size_is_rejected_before_private_decryption(self) -> None:
        self.ciphertext.write_bytes(base64.b64encode(b"short"))
        with patch.object(HANDOFF, "openssl", wraps=HANDOFF.openssl) as crypto, self.assertRaises(ValueError):
            self.decrypt()
        self.assertFalse(any(call.args[0][0] == "pkeyutl" for call in crypto.call_args_list))

    def test_fingerprint_is_checked_before_plaintext_is_written(self) -> None:
        with self.assertRaises(ValueError):
            self.decrypt("0" * 64)
        self.assertFalse((self.directory / "endpoint.txt").exists())

    def test_wrong_mgf1_is_rejected(self) -> None:
        self.ciphertext.write_bytes(base64.b64encode(encrypt(self.key / "public.pem", PLAIN, "sha1")))
        with self.assertRaises(ValueError):
            self.decrypt()
        self.assertFalse((self.directory / "endpoint.txt").exists())

    def test_dotnet_oaep_sha256_sender_matches_the_openssl_receiver(self) -> None:
        plaintext = self.directory / "dummy-endpoint.txt"
        HANDOFF.write_private(plaintext, PLAIN)
        fixture = SCRIPT.parent / "tests/fixtures/qairt-encrypt-endpoint.ps1"
        result = subprocess.run(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(fixture),
                                 "-PublicKeyFile", str(self.key / "public.pem"),
                                 "-ExpectedFingerprint", self.record["sha256_spki"],
                                 "-PlaintextFile", str(plaintext)], capture_output=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(PLAIN, result.stdout + result.stderr)
        self.ciphertext.write_bytes(result.stdout)
        self.decrypt()
        self.assertEqual((self.directory / "endpoint.txt").read_bytes(), PLAIN)

    def test_tampered_and_invalid_ciphertexts_are_rejected(self) -> None:
        original = base64.b64decode(self.ciphertext.read_bytes())
        for value in (b"invalid!", base64.b64encode(original[:-1]), base64.b64encode(bytes([original[0] ^ 1]) + original[1:])):
            with self.subTest(value=value[:8]), self.assertRaises(ValueError):
                self.ciphertext.write_bytes(value)
                self.decrypt()
        self.assertFalse((self.directory / "endpoint.txt").exists())

    def test_public_or_symlinked_private_material_is_refused(self) -> None:
        key = self.directory / "private.pem"
        key.chmod(0o644)
        with self.assertRaises(ValueError):
            self.decrypt()
        key.chmod(0o600)
        key.unlink()
        key.symlink_to(self.key / "private.pem")
        with self.assertRaises(ValueError):
            self.decrypt()

    def test_existing_endpoint_cannot_be_overwritten(self) -> None:
        endpoint = self.directory / "endpoint.txt"
        endpoint.write_bytes(b"existing-private-value")
        with self.assertRaises(FileExistsError):
            self.decrypt()
        self.assertEqual(endpoint.read_bytes(), b"existing-private-value")

    def test_endpoint_format_excludes_credentials_queries_and_control_characters(self) -> None:
        for value in (b"not-a-url", b"http://user:secret@private.invalid", b"https://private.invalid?token=secret",
                      b"https://private.invalid#fragment", b"https://private.invalid\r\n", b"x" * 319):
            with self.subTest(value=value[:12]), self.assertRaises(ValueError):
                HANDOFF.endpoint_payload(value)

    def test_utf8_byte_limit_is_an_actual_rsa_oaep_boundary(self) -> None:
        prefix = b"https://private.invalid/"
        valid = prefix + b"x" * (318 - len(prefix))
        self.ciphertext.write_bytes(base64.b64encode(encrypt(self.key / "public.pem", valid)))
        self.decrypt()
        self.assertEqual((self.directory / "endpoint.txt").read_bytes(), valid)
        with self.assertRaises(ValueError):
            HANDOFF.endpoint_payload(valid + b"x")

    def test_cli_outputs_only_public_metadata_or_a_status(self) -> None:
        command = [sys.executable, str(SCRIPT), "decrypt", "--directory", str(self.directory),
                   "--ciphertext", str(self.ciphertext), "--expected-fingerprint", self.record["sha256_spki"]]
        result = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "decrypted-locally")
        self.assertNotIn(PLAIN, result.stdout + result.stderr)
        result = subprocess.run(command, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(PLAIN, result.stdout + result.stderr)

    def test_symlinked_key_directory_is_refused(self) -> None:
        link = Path(self.working.name) / "linked-key"
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            HANDOFF.inspect(link)

    def test_cli_hides_even_an_exception_containing_the_endpoint(self) -> None:
        output, error = io.StringIO(), io.StringIO()
        command = [str(SCRIPT), "decrypt", "--directory", str(self.directory), "--ciphertext", str(self.ciphertext),
                   "--expected-fingerprint", self.record["sha256_spki"]]
        with patch.object(sys, "argv", command), patch.object(HANDOFF, "decrypt", side_effect=ValueError(PLAIN.decode())), \
                redirect_stdout(output), redirect_stderr(error):
            self.assertEqual(HANDOFF.main(), 1)
        self.assertNotIn(PLAIN.decode(), output.getvalue() + error.getvalue())
        self.assertIn("no secret output disclosed", error.getvalue())


if __name__ == "__main__":
    unittest.main()
