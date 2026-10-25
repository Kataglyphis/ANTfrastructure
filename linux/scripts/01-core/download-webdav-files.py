#!/usr/bin/env python3
"""Download a WebDAV tree, optionally filtered by extension, with the client pinned by WEBDAVCLIENT_REF."""
from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from kataglyphis_webdavclient.webdavclient import WebDavClient


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Download a WebDAV tree, optionally filtered by extension.")
    parser.add_argument("hostname", help="WebDAV server hostname")
    parser.add_argument("username", help="WebDAV server username")
    parser.add_argument("password", help="WebDAV server password")
    parser.add_argument("remote_base_path", help="Remote base path on the WebDAV server")
    parser.add_argument("local_base_path", help="Local base path to save files under")
    parser.add_argument(
        "--extension",
        default="all",
        help="only download files ending with this extension, case-insensitive;"
             " 'all' (the default) downloads the whole tree through the client",
    )
    return parser.parse_args(argv)


def download_everything(client: WebDavClient, remote: str, local: str) -> int:
    """The whole tree, through the client. No traversal of our own."""
    walk = getattr(client, "download_all_files_iterative", None)
    if walk is None:
        # The pinned client predates the method; say so instead of an AttributeError.
        print(
            "the pinned kataglyphis_webdavclient has no download_all_files_iterative; "
            "bump WEBDAVCLIENT_REF in linux/scripts/01-core/versions.env",
            file=sys.stderr,
        )
        return 2
    walk(remote, local)
    return 0


def download_filtered(client: WebDavClient, remote: str, local: str, extension: str) -> int:
    """Delegate filtering, path safety and atomic writes to the pinned client."""
    written = client.download_all_files_iterative(remote, local, extension=extension)
    print(f"downloaded {written} file(s) matching {extension}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    client = WebDavClient(args.hostname, args.username, args.password)
    Path(args.local_base_path).mkdir(parents=True, exist_ok=True)

    extension = args.extension.lower()
    try:
        if extension in ("", "all", "*"):
            return download_everything(client, args.remote_base_path, args.local_base_path)
        if not extension.startswith("."):
            extension = "." + extension
        return download_filtered(client, args.remote_base_path, args.local_base_path, extension)
    except (OSError, ValueError, TypeError) as error:
        print(f"WebDAV download failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
