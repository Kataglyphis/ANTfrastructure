import gzip
import pathlib
import sys
import tarfile
import zipfile

import package_archive_fixture as fixture

root = pathlib.Path(sys.argv[1])
license_text = (root / "LICENSE").read_bytes()
fixture.write_zip(root / "app.zip", [("assets/NOTICES.Z", gzip.compress(b"app\n\n" + license_text)),
                             ("share/doc/app/LICENSE", license_text)])
with tarfile.open(root / "app.tar.gz", "w:gz") as archive:
    archive.add(root / "tree/share/doc/app/LICENSE", arcname="app/LICENSE")
with zipfile.ZipFile(root / "wrong.zip", "w") as archive:
    archive.writestr("share/doc/app/LICENSE", b"unrelated text")
    archive.writestr("assets/NOTICES.Z", b"bad compressed content")
with zipfile.ZipFile(root / "bad-gzip.zip", "w") as archive:
    archive.writestr("assets/NOTICES.Z", b"\x1f\x8b" + b"not-a-gzip-stream")
fixture.write_symlink_zip(root / "link.zip", "LICENSE", license_text)
