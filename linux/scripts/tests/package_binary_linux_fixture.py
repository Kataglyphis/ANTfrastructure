"""Construct Linux-only filesystem and TAR controls beside the shared portable archives."""

import pathlib
import sys
import tarfile

import package_archive_fixture as fixture
from package_binary_archive_fixture import create_binary_archives

root = pathlib.Path(sys.argv[1])
data = create_binary_archives(root)
for directory in ('tree', 'symlink-tree', 'alias-tree', 'link-tree'):

    (root / directory).mkdir()
for directory in ('tree', 'symlink-tree', 'alias-tree'):
    (root / directory / 'app').mkdir()
member = 'app/onnxruntime_providers_cuda.dll'
(root / 'tree' / member).write_bytes(data)
(root / 'root-link').symlink_to(root / 'tree', target_is_directory=True)
(root / 'symlink-tree' / member).symlink_to(root / 'provider.dll')
(root / 'alias-tree' / member).write_bytes(data)
(root / 'alias-tree/app/ONNXRUNTIME_PROVIDERS_CUDA.dll').write_bytes(data)
(root / 'link-tree/app').symlink_to(root / 'tree/app', target_is_directory=True)
fixture.write_tar(root / 'app.tar', [(member, data)], 'w')
with (root / 'app-tail.tar').open('wb') as stream:
    stream.write((root / 'app.tar').read_bytes())
    stream.write(b'x' * (2 * 1024 * 1024))
fixture.write_tar(root / 'app.tar.gz', [(member, data)])
fixture.write_tar(root / 'dot.tar.gz', [('./' + member, data)])
for name, entries in {
    'duplicate': [(member, data), (member, data)],
    'duplicate-dot': [(member, data), ('./' + member, data)],
    'case': [(member, data), ('app/ONNXRUNTIME_PROVIDERS_CUDA.dll', data)],
    'double-dot': [('././' + member, data)],
    'alias': [('app/./onnxruntime_providers_cuda.dll', data)],
    'unsafe': [('../escape', b'x'), (member, data)],
}.items():
    fixture.write_tar(root / f'{name}.tar.gz', entries)
for name, kind in [('symlink', tarfile.SYMTYPE), ('hardlink', tarfile.LNKTYPE), ('directory', tarfile.DIRTYPE)]:
    info = tarfile.TarInfo(member)
    info.type = kind
    info.linkname = 'target.dll'
    fixture.write_tar(root / f'{name}.tar.gz', [('target.dll', data), info])
