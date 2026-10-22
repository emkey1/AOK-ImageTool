#!/bin/zsh
# Builds the Core ML model behind Image ▸ Colorize from DDColor (large), github.com/piddnad/DDColor.
#
#   scripts/convert-colorize-model.sh <work folder> [--install]
#
# Needs Xcode (for coremlcompiler), about 4 GB free in the work folder, and a network connection: it
# downloads Python packages (into a virtual environment inside the work folder), DDColor's code, and its
# weights (about 900 MB). The result is <work folder>/out/DDColor.mlmodelc, which you choose in
# AOK-ImageTool ▸ Settings ▸ Editing ▸ Colorize ▸ More ▸ Install from Folder… (or pass --install). The work
# folder can be deleted afterwards. DDColor's code and weights are licensed under Apache 2.0.
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <work folder> [--install]"; exit 2; }
D="${1:A}"
INSTALL="${2:-}"
COMMIT="2adb63f2656ac41cbdf7b894cddd94121a3faf13"
log() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$D/weights" "$D/out"

log "1/5 Python environment"
[[ -x "$D/venv/bin/python" ]] || /usr/bin/python3 -m venv "$D/venv"
"$D/venv/bin/pip" install --quiet --upgrade pip
"$D/venv/bin/pip" install --quiet "coremltools>=8.0,<9" "numpy<2" torch

log "2/5 DDColor's code (@ ${COMMIT:0:8})"
[[ -d "$D/src/.git" ]] || git clone --quiet https://github.com/piddnad/DDColor.git "$D/src"
git -C "$D/src" fetch --quiet --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$D/src" checkout --quiet "$COMMIT"

log "3/5 Weights (DDColor large)"
[[ -s "$D/weights/pytorch_model.bin" ]] || curl -sS -L --fail --retry 3 -C - -o "$D/weights/pytorch_model.bin" \
    https://huggingface.co/piddnad/ddcolor_modelscope/resolve/main/pytorch_model.bin

log "4/5 Converting to Core ML"
cat > "$D/convert.py" <<'PY'
import sys, types, torch, numpy as np, coremltools as ct
src, weights, out = sys.argv[1], sys.argv[2], sys.argv[3]
# The architecture without the packages' __init__ files (which pull in OpenCV and training dependencies).
for name, path in [("basicsr", "basicsr"), ("basicsr.archs", "basicsr/archs"), ("ddcolor", "ddcolor")]:
    m = types.ModuleType(name); m.__path__ = [f"{src}/{path}"]; sys.modules[name] = m
sys.path.insert(0, src)
from ddcolor.model import DDColor
model = DDColor(encoder_name="convnext-l", decoder_name="MultiScaleColorDecoder", input_size=[512, 512],
                num_output_channels=2, last_norm="Spectral", do_normalize=False, num_queries=100, num_scales=3, dec_layers=9)
state = torch.load(weights, map_location="cpu")
state = state.get("params", state) if isinstance(state, dict) else state
model.load_state_dict(state, strict=False)
model.eval()
for module in model.modules():   # bake spectral norm into plain weights
    for hook in list(module._forward_pre_hooks.values()):
        if type(hook).__name__ == "SpectralNorm":
            torch.nn.utils.remove_spectral_norm(module); break
x = torch.rand(1, 3, 512, 512)
with torch.no_grad():
    traced = torch.jit.trace(model, x)
ml = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=(1, 3, 512, 512))], outputs=[ct.TensorType(name="ab")],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS13)
ml.short_description = "DDColor (large): ab color channels for a grayscale image. Apache-2.0, github.com/piddnad/DDColor"
ml.save(f"{out}/DDColor.mlpackage")
PY
(cd "$D/out" && "$D/venv/bin/python" -I "$D/convert.py" "$D/src" "$D/weights/pytorch_model.bin" "$D/out" > "$D/convert.log" 2>&1) \
    || { log "conversion failed:"; tail -30 "$D/convert.log"; exit 1; }

log "5/5 Compiling"
rm -rf "$D/out/DDColor.mlmodelc"
xcrun coremlcompiler compile "$D/out/DDColor.mlpackage" "$D/out" >/dev/null
if [[ "$INSTALL" == "--install" ]]; then
    DEST="$HOME/Library/Application Support/com.oneopa.AOK-ImageTool/Models/Colorize"
    mkdir -p "$DEST"
    rm -rf "$DEST/DDColor.mlmodelc"
    cp -cR "$D/out/DDColor.mlmodelc" "$DEST/"
    log "Installed in $DEST"
else
    log "Done: choose $D/out/DDColor.mlmodelc in Settings ▸ Editing ▸ Colorize ▸ More ▸ Install from Folder…"
fi
