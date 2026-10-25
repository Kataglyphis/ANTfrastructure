#!/usr/bin/env python3
"""Write Meson cross-Python metadata; see docs/cross-build-verification.md#standalone-python-probes."""
import json
import pathlib
import re
import sys
import sysconfig


def main() -> None:
    output_path = pathlib.Path(sys.argv[1])
    target_triplet = sys.argv[2]
    include_dir = pathlib.Path(sys.argv[3])
    dynamic_libpython = pathlib.Path(sys.argv[4])
    pkgconfig_path = sys.argv[5]
    target_arch = target_triplet.split('-', 1)[0]

    language_version = f"{sys.version_info.major}.{sys.version_info.minor}"
    if not include_dir.is_dir():
        raise SystemExit(f"Could not determine Python include directory for {language_version}")

    cache_tag = getattr(sys.implementation, 'cache_tag', '') or f"cpython-{sys.version_info.major}{sys.version_info.minor}"
    flag_match = re.match(r'^cpython-\d+([a-z]*)$', cache_tag)
    abi_flags = list(flag_match.group(1)) if flag_match else []

    platform = sysconfig.get_platform() or f"linux-{target_arch}"
    host_multiarch = sysconfig.get_config_var('MULTIARCH') or ''
    host_arch = host_multiarch.split('-', 1)[0] if host_multiarch else ''
    if host_arch and platform.endswith(host_arch):
        platform = f"{platform[:-len(host_arch)]}{target_arch}"
    elif not platform.startswith('linux-'):
        platform = f"linux-{target_arch}"

    libpython = {
        'link_extensions': False,
    }
    if dynamic_libpython.exists():
        libpython['dynamic'] = str(dynamic_libpython)

    impl_version = getattr(sys.implementation, 'version', sys.version_info)
    cross_prefix = str(include_dir.parent.parent)
    data = {
        'schema_version': '1.0',
        'base_prefix': cross_prefix,
        'platform': platform,
        'language': {
            'version': language_version,
        },
        'implementation': {
            'name': sys.implementation.name,
            'version': {
                'major': impl_version.major,
                'minor': impl_version.minor,
                'micro': impl_version.micro,
                'releaselevel': impl_version.releaselevel,
                'serial': impl_version.serial,
            },
            'cache_tag': cache_tag,
            '_multiarch': target_triplet,
        },
        'abi': {
            'flags': abi_flags,
            'extension_suffix': f'.{cache_tag}-{target_triplet}.so',
            'stable_abi_suffix': '.abi3.so',
        },
        'libpython': libpython,
        'c_api': {
            'headers': str(include_dir),
            'pkgconfig_path': pkgconfig_path,
        },
    }

    output_path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


if __name__ == "__main__":
    main()
