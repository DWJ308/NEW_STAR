"""从 GitHub 获取 Olist 开源数据集。

策略：
  1. 优先按文件从 raw.githubusercontent.com 拉取（可增量）；
  2. raw 通道不可用时（代理/防火墙拦截常见），回退到 codeload 整仓 tar 包并解压出 data/raw。

用法：python scripts/fetch_data.py [--force]
"""

from __future__ import annotations

import argparse
import hashlib
import io
import sys
import tarfile
from pathlib import Path
from urllib.request import urlopen

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from star_pipeline.config import load_config  # noqa: E402

TARBALL_URL = "https://codeload.github.com/Ajandaghian/olist-ecommerce-etl-pipeline/tar.gz/refs/heads/main"


def sha256_of(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(chunk):
            h.update(block)
    return h.hexdigest()


def fetch_via_raw(cfg, out_dir: Path, force: bool) -> bool:
    for filename in cfg.source.files:
        target = out_dir / filename
        if target.exists() and target.stat().st_size > 1024 and not force:
            print(f"[skip] {filename} 已存在")
            continue
        url = f"{cfg.source.base_url}/{filename}"
        print(f"[get ] {url}")
        try:
            with urlopen(url, timeout=120) as resp, target.open("wb") as f:
                f.write(resp.read())
        except Exception as exc:
            print(f"[fail] {filename}: {exc}")
            return False
        if target.stat().st_size < 1024:
            print(f"[fail] {filename} 过小，疑似被拦截")
            return False
    return True


def fetch_via_tarball(out_dir: Path) -> bool:
    print("[fallback] raw 通道不可用，改用 codeload 整仓快照…")
    try:
        with urlopen(TARBALL_URL, timeout=600) as resp:
            data = resp.read()
    except Exception as exc:
        print(f"[fail] tar 包下载失败: {exc}")
        return False
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for member in tar.getmembers():
            name = Path(member.name)
            if member.isfile() and name.parts[1:3] == ("data", "raw"):
                out_dir.mkdir(parents=True, exist_ok=True)
                src = tar.extractfile(member)
                (out_dir / name.name).write_bytes(src.read())
                print(f"[ok  ] {name.name}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="忽略本地缓存强制重新下载")
    args = parser.parse_args()

    cfg = load_config()
    out_dir = cfg.paths.raw
    out_dir.mkdir(parents=True, exist_ok=True)

    ok = fetch_via_raw(cfg, out_dir, args.force) or fetch_via_tarball(out_dir)
    if not ok:
        return 1

    print("\n文件清单与指纹：")
    for filename in cfg.source.files:
        path = out_dir / filename
        if not path.exists():
            print(f"[miss] {filename}")
            continue
        print(f"{path.stat().st_size:>12,} B  sha256={sha256_of(path)[:16]}  {filename}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
