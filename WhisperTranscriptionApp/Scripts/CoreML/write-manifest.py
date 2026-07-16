#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import zipfile

MIN_AOT_HEADROOM = 512 * 1024 * 1024

parser = argparse.ArgumentParser()
parser.add_argument("--assets", type=pathlib.Path, required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--repository", required=True)
parser.add_argument("--requirements", type=pathlib.Path, required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()

models = []
for archive in sorted(args.assets.glob("ggml-*-encoder.mlmodelc.zip")):
    model_id = archive.name.removeprefix("ggml-").removesuffix("-encoder.mlmodelc.zip")
    hasher = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    with zipfile.ZipFile(archive) as zf:
        installed_bytes = sum(item.file_size for item in zf.infolist() if not item.is_dir())
    models.append({
        "modelID": model_id,
        "url": f"https://github.com/{args.repository}/releases/download/{args.tag}/{archive.name}",
        "sha256": digest,
        "archiveBytes": archive.stat().st_size,
        "installedBytes": installed_bytes,
        "aotHeadroomBytes": max(MIN_AOT_HEADROOM, installed_bytes * 2),
    })

requirements = {}
for line in args.requirements.read_text().splitlines():
    if "==" in line:
        package, version = line.split("==", 1)
        requirements[package] = version
requirements["minimumDeploymentTarget"] = "iOS17"

manifest = {
    "version": "2026.1",
    "releaseTag": args.tag,
    "toolchain": requirements,
    "models": models,
}
args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
