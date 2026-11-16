#!/bin/bash
# Compiles the segmentation models the app carries for Core ML, into the folder given as the
# first argument. Run on a Mac by the automated build; the result is kept there between
# builds. The app itself never downloads anything: the compiled models are copied into it by
# scripts/make-app.sh.
set -euo pipefail
OUT="${1:?usage: fetch-models.sh <folder>}"
mkdir -p "$OUT"

# BiRefNet_HR and BiRefNet-matting (both MIT), converted by tools/convert_birefnet.py in the
# build's Linux job and handed over as .mlpackage folders. Without one the app is built
# without that model. (Segment Anything was dropped with masking spec v3.)
for name in BiRefNet BiRefNetMatting; do
  if [ ! -d "$OUT/$name.mlmodelc" ] && [ -d "$name.mlpackage" ]; then
    work="$(mktemp -d)"
    xcrun coremlcompiler compile "$name.mlpackage" "$work"
    mv "$work/$name.mlmodelc" "$OUT/$name.mlmodelc"
    rm -rf "$work"
    echo "$name: compiled"
  fi
done

if ls "$OUT"/*.mlmodelc >/dev/null 2>&1; then du -sh "$OUT"/*.mlmodelc; else echo "no models: the app will be built without BiRefNet"; fi
