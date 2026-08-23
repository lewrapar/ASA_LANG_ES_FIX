"""Puente minimo entre PowerShell y pyuepak para PAK FIX2 de ASA."""
import argparse
import json
import sys
from pathlib import Path

from pyuepak import PakFile


def open_pak(path):
    pak = PakFile()
    pak.read(str(path))
    return pak


def inventory(args):
    pak = open_pak(args.pak)
    files = pak.list_files()
    result = {
        "pak": str(Path(args.pak).resolve()),
        "version": int(pak.version),
        "mount_point": pak.mount_point,
        "count": len(files),
        "locres": [x for x in files if x.lower().endswith(".locres")],
    }
    print(json.dumps(result, ensure_ascii=False))


def extract(args):
    pak = open_pak(args.pak)
    data = pak.read_file(args.internal)
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print(json.dumps({"internal": args.internal, "bytes": len(data), "output": str(target.resolve())}))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    inv = sub.add_parser("inventory")
    inv.add_argument("--pak", required=True)
    inv.set_defaults(func=inventory)
    ext = sub.add_parser("extract")
    ext.add_argument("--pak", required=True)
    ext.add_argument("--internal", required=True)
    ext.add_argument("--output", required=True)
    ext.set_defaults(func=extract)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"error": type(exc).__name__, "message": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise
