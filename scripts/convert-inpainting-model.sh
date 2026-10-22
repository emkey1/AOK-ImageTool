#!/bin/zsh
# Builds the Core ML model behind Crop ▸ Extend ▸ Generate from the official Stable Diffusion 1.5
# Inpainting weights, using Apple's ml-stable-diffusion converter.
#
#   scripts/convert-inpainting-model.sh <work folder> [--install]
#
# Needs Xcode (for coremlcompiler), about 10 GB free in the work folder, and a network connection: it
# downloads Python packages (into a virtual environment inside the work folder), Apple's converter, and
# the fp16 weights (about 2 GB; no safety checker). The result is <work folder>/Resources, which you choose
# in AOK-ImageTool ▸ Settings ▸ Editing ▸ Install from Folder… (or pass --install to copy it into place).
# The work folder can be deleted afterwards.
#
# The weights are licensed under CreativeML Open RAIL-M:
#   https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <work folder> [--install]"; exit 2; }
SD="${1:A}"
INSTALL="${2:-}"
W="$SD/weights"
OUT="$SD/out"
R="$OUT/Resources"
CONVERTER_COMMIT="ea2805dc1945be20561c77e5f6d1d9a5a637cda2"
BUNDLE_ID="com.oneopa.AOK-ImageTool"
log() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$SD" "$OUT"

log "1/5 Python environment"
[[ -x "$SD/venv/bin/python" ]] || /usr/bin/python3 -m venv "$SD/venv"
"$SD/venv/bin/pip" install --quiet --upgrade pip
"$SD/venv/bin/pip" install --quiet "coremltools>=8.0,<9" "diffusers==0.30.2" "transformers==4.44.2" \
    "huggingface-hub==0.24.6" "numpy<1.24" torch accelerate scipy safetensors pytest

log "2/5 Apple's converter (ml-stable-diffusion @ ${CONVERTER_COMMIT:0:8})"
if [[ ! -d "$SD/ml-stable-diffusion/.git" ]]; then
    git clone --quiet https://github.com/apple/ml-stable-diffusion.git "$SD/ml-stable-diffusion"
fi
git -C "$SD/ml-stable-diffusion" checkout --quiet "$CONVERTER_COMMIT"
# The converter imports diffusionkit only for SD3; a stand-in keeps that import from failing.
STUBS="$SD/stubs/diffusionkit"
mkdir -p "$STUBS/tests"
echo '__version__ = "not-installed"' > "$STUBS/version.py"
: > "$STUBS/__init__.py"
: > "$STUBS/tests/__init__.py"
cat > "$STUBS/tests/torch2coreml.py" <<'PY'
def convert_mmdit_to_mlpackage(*args, **kwargs):
    raise NotImplementedError("SD3 conversion needs the real diffusionkit package")

def convert_vae_to_mlpackage(*args, **kwargs):
    raise NotImplementedError("SD3 conversion needs the real diffusionkit package")
PY

log "3/5 Official SD 1.5 Inpainting weights (fp16 safetensors only)"
base="https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting/resolve/main"
for f in model_index.json scheduler/scheduler_config.json \
         text_encoder/config.json text_encoder/model.fp16.safetensors \
         tokenizer/merges.txt tokenizer/special_tokens_map.json tokenizer/tokenizer_config.json tokenizer/vocab.json \
         unet/config.json unet/diffusion_pytorch_model.fp16.safetensors \
         vae/config.json vae/diffusion_pytorch_model.fp16.safetensors; do
    mkdir -p "$W/$(dirname $f)"
    if [[ ! -s "$W/$f" ]]; then curl -sS -L --fail --retry 3 -C - -o "$W/$f" "$base/$f"; fi
    log "   $(du -h "$W/$f" | cut -f1)  $f"
done
# No safety checker or feature extractor: they aren't downloaded and inpainting doesn't use them.
"$SD/venv/bin/python" -I - "$W/model_index.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["safety_checker"] = [None, None]
d["feature_extractor"] = [None, None]
d["requires_safety_checker"] = False
json.dump(d, open(p, "w"), indent=2)
PY

log "4/5 Converting to Core ML (takes a few minutes)"
cd "$OUT"
PYTHONPATH="$SD/ml-stable-diffusion:$SD/stubs" HF_HUB_OFFLINE=1 \
"$SD/venv/bin/python" -m python_coreml_stable_diffusion.torch2coreml \
    --model-version "$W" \
    --convert-unet --convert-text-encoder --convert-vae-decoder --convert-vae-encoder \
    --attention-implementation SPLIT_EINSUM_V2 \
    -o "$OUT" > "$SD/torch2coreml.log" 2>&1 || { log "conversion failed:"; tail -40 "$SD/torch2coreml.log"; exit 1; }

log "5/5 Compiling and bundling the tokenizer"
mkdir -p "$R"
for pair in TextEncoder:text_encoder VAEDecoder:vae_decoder VAEEncoder:vae_encoder Unet:unet; do
    target="${pair%%:*}"; source="${pair##*:}"
    pkg=$(ls -d "$OUT"/*_${source}.mlpackage | head -1)
    rm -rf "$R/$target.mlmodelc"
    xcrun coremlcompiler compile "$pkg" "$R" >/dev/null
    mv "$R/$(basename "${pkg%.mlpackage}").mlmodelc" "$R/$target.mlmodelc"
    log "   $(du -sh "$R/$target.mlmodelc" | cut -f1)  $target.mlmodelc"
done
cp "$W/tokenizer/vocab.json" "$W/tokenizer/merges.txt" "$R/"

if [[ "$INSTALL" == "--install" ]]; then
    DEST="$HOME/Library/Application Support/$BUNDLE_ID/Models/StableDiffusionInpainting"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -cR "$R/" "$DEST/"
    log "Installed in $DEST"
else
    log "Done: choose $R in Settings ▸ Editing ▸ Install from Folder…"
fi
