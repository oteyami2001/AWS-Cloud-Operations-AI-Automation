#!/usr/bin/env bash
# Build build/lambda.zip: src/aiops + runtime dependencies for python3.13 / arm64 Lambda.
# Usage: scripts/build_lambda.sh            (full build, needs PyPI access)
#        NO_DEPS=1 scripts/build_lambda.sh  (code only - for CI validation / rules-only mode)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/lambda"

mkdir -p "$BUILD"
# Fresh staging directory each build (path is always inside the repo's build/ folder).
if [ -d "$STAGE" ]; then
  find "$STAGE" -mindepth 1 -delete
fi
mkdir -p "$STAGE"

if [ "${NO_DEPS:-0}" != "1" ]; then
  python3 -m pip install --quiet \
    --target "$STAGE" \
    --platform manylinux2014_aarch64 \
    --implementation cp \
    --python-version 3.13 \
    --only-binary=:all: \
    -r "$ROOT/requirements.txt"
fi

cp -R "$ROOT/src/aiops" "$STAGE/aiops"
find "$STAGE" -name "__pycache__" -type d -prune -exec rm -r {} +

# Deterministic zip (stable mtimes and ordering) so source_code_hash only changes with content.
python3 - "$STAGE" "$BUILD/lambda.zip" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            info = zipfile.ZipInfo(os.path.relpath(path, stage), date_time=(2020, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as fh:
                zf.writestr(info, fh.read())
print(f"built {out} ({os.path.getsize(out) // 1024} KiB)")
PY
