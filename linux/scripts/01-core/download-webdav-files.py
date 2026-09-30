#!/usr/bin/env python3
"""Download a WebDAV tree, optionally filtered by extension, with the client pinned by WEBDAVCLIENT_REF."""
from __future__ import annotations

import argparse
import sys
import urllib.parse
from pathlib import Path

import requests
from kataglyphis_webdavclient.webdavclient import WebDavClient


def parse_args(argv=None) -> argparse.Namespace:
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


def join_remote_url(*parts: str) -> str:
    return "/".join(p.strip("/") for p in parts if p)


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
    """One file type out of the tree, using the client's own listing calls."""
    base = Path(local)
    stack = [remote]
    written = 0
    while stack:
        current = stack.pop()
        try:
            files = client.list_files(join_remote_url(client.hostname, current))
        except Exception as exc:  # the server, not us: report and keep walking
            print(f"failed to list files under {current}: {exc}", file=sys.stderr)
            files = []
        for remote_file in files:
            try:
                name = client.filter_after_global_base_path(remote_file, remote)
            except Exception:
                name = Path(urllib.parse.unquote(remote_file)).name
            decoded = urllib.parse.unquote(name)
            if not decoded.lower().endswith(extension):
                continue
            sub = client.get_sub_path(remote_file, remote)
            if sub.endswith(decoded):
                sub = sub[: len(sub) - len(decoded)]
            if sub == decoded:
                sub = ""
            # A leading slash would make the join absolute and silently drop local_base_path.
            sub =str(sub).lstrip("/\\")
            target = base / sub / decoded
            target.parent.mkdir(parents=True, exist_ok=True)
            url = join_remote_url(client.hostname, current, name)
            response = requests.get(url, auth=client.auth, stream=True, timeout=30)
            if response.status_code != 200:
                print(f"failed to download {url}: HTTP {response.status_code}", file=sys.stderr)
                continue
            with target.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        handle.write(chunk)
            written += 1
            print(f"{url} -> {target}")
        try:
            folders = client.list_folders(current)
        except Exception as exc:
            print(f"failed to list folders under {current}: {exc}", file=sys.stderr)
            folders = []
        for folder in folders:
            stack.append("/".join(p for p in [current.rstrip("/"), folder] if p))
    print(f"downloaded {written} file(s) matching {extension}")
    return 0


def main(argv=None) -> int:
    args = parse_args(argv)
    client = WebDavClient(args.hostname, args.username, args.password)
    Path(args.local_base_path).mkdir(parents=True, exist_ok=True)

    extension = args.extension.lower()
    if extension in ("", "all", "*"):
        return download_everything(client, args.remote_base_path, args.local_base_path)
    if not extension.startswith("."):
        extension = "." + extension
    return download_filtered(client, args.remote_base_path, args.local_base_path, extension)


if __name__ == "__main__":
    raise SystemExit(main())
