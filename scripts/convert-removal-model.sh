#!/bin/zsh
# Builds the Core ML model behind Remove Objects' Remove fill from Big LaMa, github.com/advimman/lama.
#
#   scripts/convert-removal-model.sh <work folder> [--install]
#
# Needs Xcode (for coremlcompiler), about 2 GB free in the work folder, and a network connection: it
# downloads Python packages (into a virtual environment inside the work folder) and Big LaMa's weights
# (205.7 MB, the TorchScript export IOPaint uses). The result is <work folder>/out/LaMa.mlmodelc, which you
# choose in AOK-ImageTool ▸ Settings ▸ Editing ▸ Remove Objects ▸ More ▸ Install from Folder… (or pass
# --install). The work folder can be deleted afterwards. LaMa's code and weights are licensed under Apache 2.0.
#
# It's converted at full precision: LaMa's Fourier convolutions overflow at half precision. The input is a
# fixed 800 × 800 (Core ML can't take a flexible size through the Fourier transforms); the app crops and
# scales the area around what's removed to that size.
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <work folder> [--install]"; exit 2; }
D="${1:A}"
INSTALL="${2:-}"
SIZE=800
WEIGHTS_URL="https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt"
WEIGHTS_MD5="e3aa4aaa15225a33ec84f9f4bc47e500"
log() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$D/weights" "$D/out"

log "1/4 Python environment"
[[ -x "$D/venv/bin/python" ]] || /usr/bin/python3 -m venv "$D/venv"
"$D/venv/bin/pip" install --quiet --upgrade pip
"$D/venv/bin/pip" install --quiet "coremltools==7.2" "torch==2.2.0" "numpy<2"

log "2/4 Weights (Big LaMa)"
[[ -s "$D/weights/big-lama.pt" ]] || curl -sS -L --fail --retry 3 -C - -o "$D/weights/big-lama.pt" "$WEIGHTS_URL"
[[ "$(md5 -q "$D/weights/big-lama.pt")" == "$WEIGHTS_MD5" ]] || { log "big-lama.pt doesn't match its checksum"; exit 1; }

log "3/4 Converting to Core ML"
cat > "$D/convert.py" <<'PY'
import sys, torch, coremltools as ct
weights, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3])

class Removal(torch.nn.Module):
    """LaMa with 8-bit images in and out: `image` RGB 0...1 (Core ML scales it), `mask` gray, nonzero = fill."""
    def __init__(self, lama):
        super().__init__()
        self.lama = lama

    def forward(self, image, mask):
        known = (mask > 0).float()
        return torch.clamp(self.lama(image, known) * 255, min=0, max=255)

lama = torch.jit.load(weights, map_location="cpu").eval()
model = torch.jit.script(Removal(lama).eval())
ml = ct.convert(model, convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                compute_units=ct.ComputeUnit.CPU_AND_GPU, minimum_deployment_target=ct.target.macOS13,
                inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0),
                        ct.ImageType(name="mask", shape=(1, 1, size, size), color_layout=ct.colorlayout.GRAYSCALE)],
                outputs=[ct.ImageType(name="output")], skip_model_load=True)
ml.short_description = "Big LaMa: fills the masked area of an image from its surroundings. Apache-2.0, github.com/advimman/lama"
ml.save(f"{out}/LaMa.mlpackage")
PY
rm -rf "$D/out/LaMa.mlpackage"
(cd "$D/out" && "$D/venv/bin/python" -I "$D/convert.py" "$D/weights/big-lama.pt" "$D/out" "$SIZE" > "$D/convert.log" 2>&1) \
    || { log "conversion failed:"; tail -30 "$D/convert.log"; exit 1; }

log "4/4 Compiling"
rm -rf "$D/out/LaMa.mlmodelc"
xcrun coremlcompiler compile "$D/out/LaMa.mlpackage" "$D/out" >/dev/null
if [[ "$INSTALL" == "--install" ]]; then
    DEST="$HOME/Library/Application Support/com.oneopa.AOK-ImageTool/Models/Remove"
    mkdir -p "$DEST"
    rm -rf "$DEST/LaMa.mlmodelc"
    cp -cR "$D/out/LaMa.mlmodelc" "$DEST/"
    log "Installed in $DEST"
else
    log "Done: choose $D/out/LaMa.mlmodelc in Settings ▸ Editing ▸ Remove Objects ▸ More ▸ Install from Folder…"
fi
