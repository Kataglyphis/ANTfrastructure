#!/usr/bin/env python3
"""Exchange only a QAIRT service endpoint; this does not authenticate a peer or transport SDK bytes."""

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

OAEP = ["-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
        "-pkeyopt", "rsa_mgf1_md:sha256"]


def openssl(arguments: list[str], source: bytes | None = None) -> bytes:
    result = subprocess.run(["openssl", *arguments], input=source, capture_output=True,
                            timeout=60, check=False)
    if result.returncode:
        raise ValueError("OpenSSL operation failed; child output withheld")
    return result.stdout


def outside_repository(directory: Path) -> Path:
    resolved = directory.resolve()
    if any((parent / ".git").exists() for parent in (resolved, *resolved.parents)):
        raise ValueError("private handoff storage must be outside every Git checkout")
    return resolved


def write_private(path: Path, value: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(value)
        output.flush()
        os.fsync(output.fileno())


def public_record(pem: bytes) -> dict[str, str | int]:
    if not pem.startswith(b"-----BEGIN PUBLIC KEY-----\n") or b"PRIVATE KEY" in pem:
        raise ValueError("only a PEM SubjectPublicKeyInfo public key may be published")
    description = openssl(["rsa", "-pubin", "-text", "-noout"], pem)
    if not description.startswith(b"Public-Key: (3072 bit)\n"):
        raise ValueError("the handoff requires an RSA-3072 public key")
    der = openssl(["pkey", "-pubin", "-outform", "DER"], pem)
    return {"format": "PEM-SPKI", "key_bits": 3072, "sha256_spki": hashlib.sha256(der).hexdigest(),
            "public_key_pem": pem.decode("ascii")}


def keygen(directory: Path) -> dict[str, str | int]:
    directory = outside_repository(directory)
    directory.mkdir(mode=0o700, parents=True)
    private = openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072"])
    write_private(directory / "private.pem", private)
    public = openssl(["pkey", "-pubout"], private)
    record = public_record(public)
    write_private(directory / "public.pem", public)
    write_private(directory / "public-metadata.json", (json.dumps(record, indent=2) + "\n").encode())
    return record


def private_directory(directory: Path) -> Path:
    if directory.is_symlink():
        raise ValueError("private handoff storage must not be a symlink")
    directory = outside_repository(directory)
    for path, is_directory in ((directory, True), (directory / "private.pem", False)):
        info = path.lstat()
        correct_type = stat.S_ISDIR(info.st_mode) if is_directory else stat.S_ISREG(info.st_mode)
        if not correct_type or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("private handoff ownership or permissions are unsafe")
    return directory


def inspect(directory: Path) -> dict[str, str | int]:
    directory = private_directory(directory)
    public = openssl(["pkey", "-in", str(directory / "private.pem"), "-pubout"])
    record = public_record(public)
    if record != public_record((directory / "public.pem").read_bytes()):
        raise ValueError("the private and published public keys do not match")
    return record


def endpoint_payload(value: bytes) -> bytes:
    if not 0 < len(value) <= 318:
        raise ValueError("endpoint payload has an invalid size")
    text = value.decode("utf-8")
    parsed = urlsplit(text)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("decrypted payload is not a WebDAV endpoint")
    if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        raise ValueError("the endpoint must carry no credentials, query or fragment")
    if any(ord(character) <= 32 or ord(character) == 127 for character in text):
        raise ValueError("the endpoint must carry no whitespace or control characters")
    return value


def decrypt(directory: Path, ciphertext: Path, expected: str) -> dict[str, str]:
    directory = private_directory(directory)
    record = inspect(directory)
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or expected != record["sha256_spki"]:
        raise ValueError("the expected public-key fingerprint does not match")
    encoded = b"".join(ciphertext.read_bytes().split())
    cipher = base64.b64decode(encoded, validate=True)
    if len(cipher) != 384:
        raise ValueError("RSA-3072 ciphertext must contain exactly 384 bytes")
    plain = openssl(["pkeyutl", "-decrypt", "-inkey", str(directory / "private.pem"), *OAEP], cipher)
    write_private(directory / "endpoint.txt", endpoint_payload(plain))
    return {"status": "decrypted-locally", "sha256_spki": expected}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("keygen", "public", "decrypt"):
        command = commands.add_parser(name)
        command.add_argument("--directory", required=True, type=Path)
        if name == "decrypt":
            command.add_argument("--ciphertext", required=True, type=Path)
            command.add_argument("--expected-fingerprint", required=True)
    args = parser.parse_args()
    result: object
    try:
        if args.command == "keygen":
            result = keygen(args.directory)
        elif args.command == "public":
            result = inspect(args.directory)
        else:
            result = decrypt(args.directory, args.ciphertext, args.expected_fingerprint)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        print("qairt-key-handoff: operation failed; no secret output disclosed", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
