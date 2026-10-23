#!/bin/zsh
# Builds the Core ML models behind Image ▸ Fix Blur: Restormer's motion and defocus deblurring models (camera
# shake and out of focus, github.com/swz30/Restormer, MIT) and GFPGAN v1.4 (faces, github.com/TencentARC/GFPGAN,
# Apache 2.0).
#
#   scripts/convert-sharpen-models.sh <work folder> [--install]
#
# Needs Xcode (for coremlcompiler), about 3 GB free in the work folder, and a network connection: it
# downloads Python packages (into a virtual environment inside the work folder), the models' layer
# definitions, and their weights (105 MB, 105 MB and 349 MB). The results are <work folder>/out/Shake.mlmodelc,
# Focus.mlmodelc and Faces.mlmodelc, which you install in AOK-ImageTool ▸ Settings ▸ Editing ▸ Fix Blur and Fix
# Blur: Faces ▸ More ▸ Install from Folder… (choose the out folder), or pass --install. The work folder can be
# deleted afterwards.
#
# Restormer works on 384 × 384 tiles (the size it was last trained at), in half precision; GFPGAN on one
# 512 × 512 face aligned to its template, in full precision (StyleGAN's weight demodulation overflows in half
# precision, giving a flat color).
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <work folder> [--install]"; exit 2; }
D="${1:A}"
INSTALL="${2:-}"
RESTORMER_COMMIT="68dc6ac472db26f16361150cb7a96a1bc87da93f"
GFPGAN_COMMIT="7552a7791caad982045a7bbe5634bbf1cd5c8679"
RESTORMER_RELEASE="https://github.com/swz30/Restormer/releases/download/v1.0"
MOTION_SHA256="194e38fb5b607c9dc5a5b3e08e65b2e79ee2bf0ef5048e0612f6b2ff2f79da31"
DEFOCUS_SHA256="7dce451f33f8f5e0faf7c4e3996e5dcc1bd425ecd1ada99b0f9750e490fd4c9e"
GFPGAN_URL="https://github.com/TencentARC/GFPGAN/releases/download/v1.3.4/GFPGANv1.4.pth"
GFPGAN_SHA256="e2cd4703ab14f4d01fd1383a8a8b266f9a5833dacee8e6a79d3bf21a1b6be5ad"
log() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$D/weights" "$D/out" "$D/src/gfpgan_archs"

log "1/5 Python environment"
[[ -x "$D/venv/bin/python" ]] || /usr/bin/python3 -m venv "$D/venv"
"$D/venv/bin/pip" install --quiet --upgrade pip
"$D/venv/bin/pip" install --quiet "coremltools==7.2" "torch==2.2.0" "numpy<2" "einops==0.8.2"

log "2/5 Layer definitions (Restormer @ ${RESTORMER_COMMIT:0:8}, GFPGAN @ ${GFPGAN_COMMIT:0:8})"
[[ -s "$D/src/restormer_arch.py" ]] || curl -sS -L --fail -o "$D/src/restormer_arch.py" \
    "https://raw.githubusercontent.com/swz30/Restormer/$RESTORMER_COMMIT/basicsr/models/archs/restormer_arch.py"
for f in gfpganv1_clean_arch.py stylegan2_clean_arch.py; do
    [[ -s "$D/src/gfpgan_archs/$f" ]] || curl -sS -L --fail -o "$D/src/gfpgan_archs/$f" \
        "https://raw.githubusercontent.com/TencentARC/GFPGAN/$GFPGAN_COMMIT/gfpgan/archs/$f"
done
touch "$D/src/gfpgan_archs/__init__.py"

log "3/5 Weights"
fetch() {   # <file> <url> <sha256>
    [[ -s "$D/weights/$1" ]] || curl -sS -L --fail --retry 3 -o "$D/weights/$1" "$2"
    [[ "$(shasum -a 256 "$D/weights/$1" | cut -d' ' -f1)" == "$3" ]] || { log "$1 doesn't match its checksum"; exit 1; }
}
fetch restormer-motion_deblurring.pth "$RESTORMER_RELEASE/motion_deblurring.pth" "$MOTION_SHA256"
fetch restormer-single_image_defocus_deblurring.pth "$RESTORMER_RELEASE/single_image_defocus_deblurring.pth" "$DEFOCUS_SHA256"
fetch GFPGANv1.4.pth "$GFPGAN_URL" "$GFPGAN_SHA256"

log "4/5 Converting to Core ML"
cat > "$D/convert.py" <<'PY'
import sys, types, torch, torch.nn as nn, coremltools as ct
src, weights, out = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, src)

# --- Restormer (camera shake, out of focus): the same network with two sets of weights. Its layer norms'
# variance written out (Core ML Tools has no `var`); the same arithmetic.
import restormer_arch
from restormer_arch import Restormer

def with_bias(self, x):
    mu = x.mean(-1, keepdim=True)
    sigma = (x - mu).pow(2).mean(-1, keepdim=True)
    return (x - mu) / torch.sqrt(sigma + 1e-5) * self.weight + self.bias

def bias_free(self, x):
    sigma = (x - x.mean(-1, keepdim=True)).pow(2).mean(-1, keepdim=True)
    return x / torch.sqrt(sigma + 1e-5) * self.weight

restormer_arch.WithBias_LayerNorm.forward = with_bias
restormer_arch.BiasFree_LayerNorm.forward = bias_free

class Deblur(nn.Module):
    """8-bit in and out: `image` RGB 0...1 (Core ML scales it)."""
    def __init__(self, net):
        super().__init__(); self.net = net
    def forward(self, image):
        return torch.clamp(self.net(image) * 255, 0, 255)

side = 384
for name, file, about in [("Shake", "restormer-motion_deblurring.pth", "removes camera-shake (motion) blur"),
                          ("Focus", "restormer-single_image_defocus_deblurring.pth", "sharpens an out-of-focus picture")]:
    net = Restormer(inp_channels=3, out_channels=3, dim=48, num_blocks=[4, 6, 6, 8], num_refinement_blocks=4, heads=[1, 2, 4, 8],
                    ffn_expansion_factor=2.66, bias=False, LayerNorm_type="WithBias", dual_pixel_task=False)
    net.load_state_dict(torch.load(f"{weights}/{file}", map_location="cpu")["params"], strict=True)
    traced = torch.jit.trace(Deblur(net.eval()).eval(), torch.rand(1, 3, side, side))
    # (Half precision: on the GPU it matches full precision within 1/255. The app doesn't use the Neural
    # Engine, where it doesn't.)
    ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS13,
                    inputs=[ct.ImageType(name="image", shape=(1, 3, side, side), scale=1 / 255.0)], outputs=[ct.ImageType(name="output")])
    ml.short_description = f"Restormer: {about} (384 x 384 tiles). MIT, github.com/swz30/Restormer"
    ml.save(f"{out}/{name}.mlpackage")

# --- GFPGAN v1.4 (faces): its own layer definitions, without BasicSR (only a registry and an init helper).
registry = types.ModuleType("basicsr.utils.registry")
registry.ARCH_REGISTRY = types.SimpleNamespace(register=lambda *a, **k: (lambda c: c))
arch_util = types.ModuleType("basicsr.archs.arch_util")
arch_util.default_init_weights = lambda *a, **k: None
for name, module in [("basicsr", types.ModuleType("basicsr")), ("basicsr.utils", types.ModuleType("basicsr.utils")),
                     ("basicsr.archs", types.ModuleType("basicsr.archs")), ("basicsr.utils.registry", registry),
                     ("basicsr.archs.arch_util", arch_util)]:
    sys.modules[name] = module
from gfpgan_archs.gfpganv1_clean_arch import GFPGANv1Clean

gfpgan = GFPGANv1Clean(out_size=512, num_style_feat=512, channel_multiplier=2, decoder_load_path=None, fix_decoder=False,
                       num_mlp=8, input_is_latent=True, different_w=True, narrow=1, sft_half=True)
state = torch.load(f"{weights}/GFPGANv1.4.pth", map_location="cpu")
gfpgan.load_state_dict(state["params_ema"] if "params_ema" in state else state["params"], strict=True)

class Faces(nn.Module):
    """A 512 x 512 aligned face, 8-bit in and out (the model works in -1...1). The noise is the model's own
    fixed noise, so a face comes out the same every time."""
    def __init__(self, net):
        super().__init__(); self.net = net
    def forward(self, image):
        restored = self.net(image, return_rgb=False, randomize_noise=False)[0]
        return torch.clamp((restored + 1) * 127.5, 0, 255)

traced = torch.jit.trace(Faces(gfpgan.eval()).eval(), torch.rand(1, 3, 512, 512) * 2 - 1)
ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS13,
                inputs=[ct.ImageType(name="image", shape=(1, 3, 512, 512), scale=2 / 255.0, bias=[-1, -1, -1])],
                outputs=[ct.ImageType(name="output")])
ml.short_description = "GFPGAN v1.4: restores a blurry or degraded face (512 x 512, aligned). Apache-2.0, github.com/TencentARC/GFPGAN"
ml.save(f"{out}/Faces.mlpackage")
PY
rm -rf "$D/out/"*.mlpackage
(cd "$D/out" && "$D/venv/bin/python" -I "$D/convert.py" "$D/src" "$D/weights" "$D/out" > "$D/convert.log" 2>&1) \
    || { log "conversion failed:"; tail -30 "$D/convert.log"; exit 1; }

log "5/5 Compiling"
for m in Shake Focus Faces; do
    rm -rf "$D/out/$m.mlmodelc"
    xcrun coremlcompiler compile "$D/out/$m.mlpackage" "$D/out" >/dev/null
done
if [[ "$INSTALL" == "--install" ]]; then
    DEST="$HOME/Library/Application Support/com.oneopa.AOK-ImageTool/Models"
    for m in Shake Focus Faces; do
        mkdir -p "$DEST/$m"
        rm -rf "$DEST/$m/$m.mlmodelc"
        cp -cR "$D/out/$m.mlmodelc" "$DEST/$m/"
    done
    log "Installed in $DEST"
else
    log "Done: in Settings ▸ Editing ▸ Fix Blur (and Fix Blur: Faces) ▸ More ▸ Install from Folder…, choose $D/out"
fi
