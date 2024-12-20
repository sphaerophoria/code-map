#!/usr/bin/env python3

from argparse import ArgumentParser
from tempfile import TemporaryDirectory
from pathlib import Path
import subprocess
import shutil

script_dir = Path(__file__).parent
project_root = script_dir.parent.parent
recording_dir = script_dir / "recording"

def parse_args():
    parser = ArgumentParser(description="Update recording data relative to a specific path")
    parser.add_argument("scratch_dir", help="Where to make recording relative to");

    return parser.parse_args()


def main(scratch_dir):
    shutil.rmtree(recording_dir)
    with TemporaryDirectory(dir=scratch_dir) as d_s:
        d = Path(d_s)
        shutil.copytree(script_dir, d / "data")

        subprocess.run([
            str(project_root / "zig-out" / "bin" / "code-map"),
            "--config", str(project_root / "res" / "config.json"),
            "--scan-dir", str(d / "data"),
            "--recording-dir", str(recording_dir),
        ], check=True)

        with open(script_dir / "recording_root.txt", "w") as f:
            f.write(str(d / "data"))

if __name__ == '__main__':
    main(**vars(parse_args()))
