#!/usr/bin/env python3
"""Preserve a stopped producer's verified local BuildKit cache in a fresh namespace; no build acceptance."""

import argparse
import json
from pathlib import Path

from buildcache_transfer import transfer_cache, verify_rendered_import, verify_transfer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--dry-run-log', type=Path)
    parser.add_argument('--image-tag')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--producer-proof', type=Path)
    args = parser.parse_args()
    inputs = (args.source, args.destination, args.producer_proof)
    if (args.dry_run_log is not None or args.image_tag is not None) and not (args.verify_only and args.dry_run_log and args.image_tag):
        parser.error('--dry-run-log and --image-tag require each other and --verify-only')
    if args.verify_only:
        if any(value is not None for value in inputs):
            parser.error('--verify-only takes only --receipt')
        result = verify_rendered_import(args.receipt, args.dry_run_log, args.image_tag) if args.dry_run_log else verify_transfer(args.receipt)
    else:
        if any(value is None for value in inputs):
            parser.error('seeding requires --source, --destination and --producer-proof')
        result = transfer_cache(args.source, args.destination, args.producer_proof, args.receipt)
    print(json.dumps({key: result[key] for key in ('status', 'verified_unique_blobs', 'shared_unique_bytes', 'cache_hits_claimed',
                                                 'rendered_import_verified', 'dry_run_log_sha256', 'rendered_image') if key in result}))


if __name__ == '__main__':
    main()
