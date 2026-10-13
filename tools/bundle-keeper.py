#!/usr/bin/env python3
"""Rebuild the vendored runtime from integrity-checked npm archives, without npm install.

Normal use and all tests are offline: this maintenance command alone downloads packages.
The compiler used here is esbuild, not the Solidity compiler (Foundry pins solc separately).
"""
import base64
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    lock = json.loads((ROOT / "keeper/vendor/packages.json").read_text())
    with tempfile.TemporaryDirectory(prefix="catwars-vendor-") as temporary:
        stage = Path(temporary)
        aliases = []
        for package in lock:
            archive = urllib.request.urlopen(package["tarball"]).read()
            algorithm, expected = package["integrity"].split("-", 1)
            actual = base64.b64encode(hashlib.new(algorithm, archive).digest()).decode()
            if actual != expected:
                raise ValueError(f"Integrity failure: {package['name']}")
            destination = stage / package["name"]
            with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
                for member in tar.getmembers():
                    parts = PurePosixPath(member.name).parts[1:]
                    if not member.isfile() or any(
                        p in {"..", ".git", ".github", "node_modules"} or p.startswith(".env") for p in parts
                    ):
                        continue
                    path = destination.joinpath(*parts)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(tar.extractfile(member).read())
            if package["name"] != "@esbuild/linux-x64":
                aliases.append(f"--alias:{package['name']}={destination}")
        compiler = stage / "@esbuild/linux-x64/bin/esbuild"
        compiler.chmod(0o755)
        subprocess.run([
            str(compiler), "keeper/vendor-entry.mjs", "--bundle", "--format=esm", "--platform=node",
            "--target=node22", "--minify", "--legal-comments=eof", "--outfile=keeper/vendor/viem.mjs",
            "--banner:js=// viem 2.38.5 and dependencies. See packages.json and licenses/.",
            *aliases,
        ], cwd=ROOT, check=True)
    runtime = ROOT / "keeper/vendor/viem.mjs"
    (ROOT / "keeper/vendor/viem.sha256").write_text(hashlib.sha256(runtime.read_bytes()).hexdigest() + "  viem.mjs\n")


if __name__ == "__main__":
    main()
