import pathlib
import sys
import warnings
import zipfile

import package_archive_fixture as fixture


def create_binary_archives(root: pathlib.Path) -> bytes:
    data = (b'MZ\r\n\x00\xffabcdef' * (18 * 1024 * 1024 // 12 + 1))[:18 * 1024 * 1024]
    (root / 'provider.dll').write_bytes(data)
    (root / 'wrong.dll').write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
    (root / 'empty.dll').write_bytes(b'')
    for name in ('app.zip', 'app.msix', 'app.whl'):
        fixture.write_zip(root / name, [('app/onnxruntime_providers_cuda.dll', data), ('app/shared.dll', b'shared\r\n'), ('app/source.patch', b'')], zipfile.ZIP_DEFLATED)
    (root / 'shared.dll').write_bytes(b'shared\r\n')
    with zipfile.ZipFile(root / 'duplicate.zip', 'w') as archive:
        archive.writestr('app/onnxruntime_providers_cuda.dll', data)
        archive.writestr('app/ONNXRUNTIME_PROVIDERS_CUDA.dll', data)
    with zipfile.ZipFile(root / 'alias.zip', 'w') as archive:
        archive.writestr('app/onnxruntime_providers_cuda.dll', data)
        archive.writestr('app/./onnxruntime_providers_cuda.dll', data)
    with zipfile.ZipFile(root / 'leading-dot.zip', 'w') as archive:
        archive.writestr('./app/onnxruntime_providers_cuda.dll', data)
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        with zipfile.ZipFile(root / 'duplicate-exact.zip', 'w') as archive:
            archive.writestr('app/onnxruntime_providers_cuda.dll', data)
            archive.writestr('app/onnxruntime_providers_cuda.dll', data)
    fixture.write_symlink_zip(root / 'symlink.zip', 'app/onnxruntime_providers_cuda.dll', data)
    special = zipfile.ZipInfo('app/onnxruntime_providers_cuda.dll')
    special.create_system = 3
    special.external_attr = 0o010600 << 16
    with zipfile.ZipFile(root / 'special.zip', 'w') as archive:
        archive.writestr(special, data)
    with zipfile.ZipFile(root / 'unsafe.zip', 'w') as archive:
        archive.writestr('../escape', b'x')
        archive.writestr('app/onnxruntime_providers_cuda.dll', data)
    return data


if __name__ == "__main__":
    create_binary_archives(pathlib.Path(sys.argv[1]))
