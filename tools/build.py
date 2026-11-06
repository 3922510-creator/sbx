#!/usr/bin/env python3
"""Build the self-contained SBX script from modular src/ components."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARTS = (
    "header",
    "system",
    "network",
    "proxy_core",
    "proxy_nodes",
    "proxy_features",
    "uninstall",
    "menus",
)


def build():
    chunks = []
    for part in PARTS:
        content = (ROOT / "src" / f"{part}.sh").read_text(encoding="utf-8").rstrip()
        chunks.append(content)
    return "\n\n".join(chunks) + "\n"


if __name__ == "__main__":
    out_file = ROOT / "sbx.sh"
    out_file.write_text(build(), encoding="utf-8")
    out_file.chmod(0o755)
    print(f"Build succeeded: {out_file} ({out_file.stat().st_size} bytes)")
