#!/usr/bin/env python3
"""Export the reviewed source manifest without local metadata or Git history."""
from pathlib import Path
import gzip
import io
import tarfile
import hashlib

root = Path(__file__).resolve().parent.parent
manifest = (root / "RELEASE_FILES.txt").read_text().splitlines()
assert len(manifest) == len(set(manifest)), "Duplicate release entry"
for name in manifest:
    p = Path(name)
    assert not p.is_absolute() and ".." not in p.parts, "Invalid release entry"
    assert not any(part in {".build", "dist", ".git", ".DS_Store"} for part in p.parts), "Excluded directory"
    assert (root / p).is_file(), "Missing release entry"
    assert not any(parent.is_symlink() for parent in [root / p, *(root / p).parents]), "No symlinks in release"
    (root / p).read_text(encoding="utf-8")  # Reject accidental binary payloads.

out = root / "dist" / "EasyClash-public-source.tar.gz"
out.parent.mkdir(exist_ok=True)
with out.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz, tarfile.open(fileobj=gz, mode="w|", format=tarfile.USTAR_FORMAT) as archive:
    for name in manifest:
        data = (root / name).read_bytes()
        info = tarfile.TarInfo("EasyClash/" + name)
        info.size = len(data)
        info.mode = 0o755 if name.startswith("scripts/") else 0o644
        info.mtime = 0
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        archive.addfile(info, io.BytesIO(data))
print(f"Exported {len(manifest)} reviewed text files: {out.name}")
print("SHA256 " + hashlib.sha256(out.read_bytes()).hexdigest())
