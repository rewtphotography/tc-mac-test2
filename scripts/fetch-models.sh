#!/bin/bash
# Fetches the segmentation models the app carries and compiles them for Core ML, into the
# folder given as the first argument. Run on a Mac by the automated build; the result is
# cached there, so this only does work when the list below changes. The app itself never
# downloads anything: the compiled models are copied into it by scripts/make-app.sh.
set -euo pipefail
OUT="${1:?usage: fetch-models.sh <folder>}"
mkdir -p "$OUT"

# Segment Anything 2.1, Apple's Core ML conversion (Apache-2.0).
SAM_REPO="${SAM_REPO:-apple/coreml-sam2.1-large}"
SAM_PREFIX="${SAM_PREFIX:-SAM2_1Large}"

fetch_package() { # <repo> <package name> <compiled name>
  local repo="$1" package="$2" name="$3"
  if [ -d "$OUT/$name.mlmodelc" ]; then echo "$name: already here"; return; fi
  local work; work="$(mktemp -d)"
  local base="https://huggingface.co/$repo/resolve/main/$package.mlpackage"
  mkdir -p "$work/$package.mlpackage/Data/com.apple.CoreML/weights"
  for file in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    curl -fsSL --retry 4 --retry-delay 5 -o "$work/$package.mlpackage/$file" "$base/$file"
  done
  xcrun coremlcompiler compile "$work/$package.mlpackage" "$work/out"
  rm -rf "$OUT/$name.mlmodelc"
  mv "$work/out/$package.mlmodelc" "$OUT/$name.mlmodelc"
  rm -rf "$work"
  echo "$name: compiled from $repo"
}

# BiRefNet_HR (MIT), converted by tools/convert_birefnet.py in the build's Linux job and
# handed over as BiRefNet.mlpackage. Without it the app is built without that model.
if [ ! -d "$OUT/BiRefNet.mlmodelc" ] && [ -d BiRefNet.mlpackage ]; then
  work="$(mktemp -d)"
  xcrun coremlcompiler compile BiRefNet.mlpackage "$work"
  mv "$work/BiRefNet.mlmodelc" "$OUT/BiRefNet.mlmodelc"
  rm -rf "$work"
  echo "BiRefNet: compiled"
fi

fetch_package "$SAM_REPO" "${SAM_PREFIX}ImageEncoderFLOAT16" SAMImageEncoder
fetch_package "$SAM_REPO" "${SAM_PREFIX}PromptEncoderFLOAT16" SAMPromptEncoder
fetch_package "$SAM_REPO" "${SAM_PREFIX}MaskDecoderFLOAT16" SAMMaskDecoder
du -sh "$OUT"/*.mlmodelc
