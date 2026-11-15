#!/bin/bash
# Compiles the segmentation model the app carries for Core ML, into the folder given as the
# first argument. Run on a Mac by the automated build; the result is kept there between
# builds. The app itself never downloads anything: the compiled model is copied into it by
# scripts/make-app.sh.
set -euo pipefail
OUT="${1:?usage: fetch-models.sh <folder>}"
mkdir -p "$OUT"

# BiRefNet_HR (MIT), converted by tools/convert_birefnet.py in the build's Linux job and
# handed over as BiRefNet.mlpackage. Without it the app is built without that model.
# (Segment Anything was dropped with masking spec v3.)
if [ ! -d "$OUT/BiRefNet.mlmodelc" ] && [ -d BiRefNet.mlpackage ]; then
  work="$(mktemp -d)"
  xcrun coremlcompiler compile BiRefNet.mlpackage "$work"
  mv "$work/BiRefNet.mlmodelc" "$OUT/BiRefNet.mlmodelc"
  rm -rf "$work"
  echo "BiRefNet: compiled"
fi

if ls "$OUT"/*.mlmodelc >/dev/null 2>&1; then du -sh "$OUT"/*.mlmodelc; else echo "no models: the app will be built without BiRefNet"; fi
