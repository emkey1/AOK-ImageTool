# Third-party notices

AOK-ImageTool itself is MIT licensed (see [LICENSE](LICENSE)). It uses only Apple's frameworks and bundles no
third-party code. Two optional features use machine-learning models that are **not** part of the app: you
download them separately, from Settings ▸ Editing or when you first use the feature, and their own licenses
apply to them.

## Optional models

### Stable Diffusion 1.5 Inpainting (Generate: Extend and Generate a Background)

- Source: [stable-diffusion-v1-5/stable-diffusion-inpainting](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting),
  converted to Core ML (fp16) with [scripts/convert-inpainting-model.sh](scripts/convert-inpainting-model.sh).
  The conversion changes the files' format, not the model.
- License: [CreativeML Open RAIL-M](https://huggingface.co/spaces/CompVis/stable-diffusion-license),
  Copyright (c) 2022 Robin Rombach and Patrick Esser and contributors. The license comes with the download
  (LICENSE.txt and NOTICE.txt in each archive).
- The license restricts how the model may be used (its Attachment A: no unlawful use, no harming minors,
  no defamation or harassment, no generating false information to harm others, no discriminatory or medical
  misuse, among others). The app asks you to accept the license before it downloads the model, and anyone who
  uses the model must follow those restrictions.

### DDColor (Colorize)

- Source: [piddnad/DDColor](https://github.com/piddnad/DDColor) (Kang et al., *DDColor: Towards Photo-Realistic
  Image Colorization via Dual Decoders*, ICCV 2023), large model weights from
  [piddnad/ddcolor_modelscope](https://huggingface.co/piddnad/ddcolor_modelscope), converted to Core ML with
  [scripts/convert-colorize-model.sh](scripts/convert-colorize-model.sh).
- License: [Apache License 2.0](https://github.com/piddnad/DDColor/blob/master/LICENSE). The license comes with
  the download (LICENSE.txt and NOTICE.txt in the archive).

### LaMa (Remove Objects › Erase)

- Source: [advimman/lama](https://github.com/advimman/lama) (Suvorov et al., *Resolution-robust Large Mask
  Inpainting with Fourier Convolutions*, WACV 2022), the Big LaMa weights in the TorchScript export
  [IOPaint](https://github.com/Sanster/IOPaint) uses ([Sanster/models](https://github.com/Sanster/models/releases/tag/add_big_lama)),
  converted to Core ML with [scripts/convert-removal-model.sh](scripts/convert-removal-model.sh), after
  [mallman/CoreMLaMa](https://github.com/mallman/CoreMLaMa) (Apache License 2.0).
- License: [Apache License 2.0](https://github.com/advimman/lama/blob/main/LICENSE). The license comes with the
  download (LICENSE.txt and NOTICE.txt in the archive).

### Restormer (Fix Blur: Out of Focus, Camera Shake)

- Source: [swz30/Restormer](https://github.com/swz30/Restormer) (Zamir et al., *Restormer: Efficient Transformer for
  High-Resolution Image Restoration*, CVPR 2022), the v1.0 release's single-image defocus and motion deblurring
  weights, converted to Core ML with [scripts/convert-sharpen-models.sh](scripts/convert-sharpen-models.sh).
- License: [MIT](https://github.com/swz30/Restormer/blob/main/LICENSE.md), Copyright (c) 2022 Syed Waqas Zamir and
  contributors. The license comes with the download (LICENSE.txt and NOTICE.txt in the archive).

### GFPGAN v1.4 (Fix Blur: Restore Faces)

- Source: [TencentARC/GFPGAN](https://github.com/TencentARC/GFPGAN) (Wang et al., *Towards Real-World Blind Face
  Restoration with Generative Facial Prior*, CVPR 2021), the v1.3.4 release's GFPGANv1.4.pth with its "clean"
  architecture, converted to Core ML with [scripts/convert-sharpen-models.sh](scripts/convert-sharpen-models.sh).
- License: [Apache License 2.0](https://github.com/TencentARC/GFPGAN/blob/master/LICENSE), except for the third-party
  components that license lists: StyleGAN2 code (from stylegan2-pytorch, and NVIDIA's StyleGAN2, under the NVIDIA
  license) and DFDNet code (CC BY-NC-SA 4.0). The clean architecture used here doesn't include NVIDIA's custom CUDA
  operators. The model was trained on FFHQ, whose images are under CC BY-NC-SA 4.0. The full license comes with the
  download (LICENSE.txt and NOTICE.txt in the archive).

## Conversion scripts

The scripts in [scripts/](scripts) download and run, in a throwaway Python environment, tools that aren't part
of this repository:

- [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion): MIT License, Copyright (c) 2024
  Apple Inc.
- [piddnad/DDColor](https://github.com/piddnad/DDColor): Apache License 2.0.
- Big LaMa's weights ([advimman/lama](https://github.com/advimman/lama)): Apache License 2.0.
- [swz30/Restormer](https://github.com/swz30/Restormer) (its layer definitions and weights): MIT License.
- [TencentARC/GFPGAN](https://github.com/TencentARC/GFPGAN) (its layer definitions and weights): Apache License 2.0,
  with the exceptions above.
- einops: MIT License.
- PyTorch, Core ML Tools, Hugging Face libraries and their dependencies, under their own licenses.

The Stable Diffusion inference in the app (CLIP tokenizer, DPM-Solver++ scheduler, the denoising loop) is this
app's own Swift code; Apple's ml-stable-diffusion is the reference implementation of the same model on Core ML.

## Apple's upscaling model

AI upscaling uses a model that macOS itself downloads and manages; it isn't distributed with this app.

## Test images

The photos in [TestImages](TestImages) were generated for this project with Stable Diffusion 1.5 on a Mac; they
show no real people or places. The other test files there were made by script. They're covered by this
repository's license.
