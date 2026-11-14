#!/usr/bin/env python3
"""Build an Apple Silicon disk image with the original, pinned NetBird installer."""
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request

root = Path(__file__).resolve().parents[1]
dist = root / "dist"
version = "0.83.1"
name = f"netbird_{version}_darwin_arm64.pkg"
digest = "a96e402ba31ff4804a88ad04fac2e3f9e695f0e80440f39a68c2cb3f661a0d2a"
url = f"https://github.com/netbirdio/netbird/releases/download/v{version}/{name}"
if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("Build this image on an Apple Silicon Mac.")

subprocess.run(["bash", "scripts/build-app.sh"], cwd=root, check=True)
with tempfile.TemporaryDirectory() as tmp:
    stage = Path(tmp) / "image"
    stage.mkdir()
    app = stage / "EasyClash.app"
    subprocess.run(["ditto", str(dist / app.name), str(app)], check=True)
    pkg = stage / name
    cached = dist / "vendor" / name
    if cached.exists():
        shutil.copyfile(cached, pkg)
    else:
        with urllib.request.urlopen(url, timeout=60) as response, pkg.open("wb") as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(pkg.read_bytes()).hexdigest() != digest:
        raise SystemExit("NetBird installer SHA-256 does not match the pinned release.")
    signature = subprocess.check_output(["pkgutil", "--check-signature", str(pkg)], text=True)
    if "Developer ID Installer: NetBird GmbH (TA739QLA7A)" not in signature:
        raise SystemExit("Unexpected NetBird installer signer.")
    (stage / "Applications").symlink_to("/Applications")
    for notice in [root / "LICENSE", root / "THIRD_PARTY_NOTICES.md", *sorted((root / "THIRD_PARTY").glob("*.txt"))]:
        shutil.copyfile(notice, stage / notice.name)
    (stage / "安装说明.txt").write_text(
        "适用于 Apple Silicon，macOS 13 或更新版本。\n"
        "1. 将 EasyClash.app 拖到 Applications。EasyClash 使用临时签名，未经公证。\n"
        "2. 已经使用 NetBird 的设备可以跳过安装。首次安装请运行同一镜像内的官方 NetBird pkg。\n"
        "3. 打开 EasyClash 设置，选择 NetBird 和代理客户端，填写公司域名后点“连接 NetBird 并开启协同”。首次登录按浏览器提示授权。\n"
        "4. 如需卸载：先关闭协同，然后按项目的 docs/OPERATIONS.md 清理恢复守护。NetBird 使用其独立卸载流程。\n",
        encoding="utf-8",
    )
    out = dist / "EasyClash-0.4.3-NetBird-macOS-arm64.dmg"
    subprocess.run(["hdiutil", "create", "-ov", "-format", "UDZO", "-volname", "EasyClash", "-srcfolder", str(stage), str(out)], check=True)
    subprocess.run(["hdiutil", "verify", str(out)], check=True)
    print(out)
