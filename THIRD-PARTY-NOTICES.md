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

## Conversion scripts

The scripts in [scripts/](scripts) download and run, in a throwaway Python environment, tools that aren't part
of this repository:

- [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion): MIT License, Copyright (c) 2024
  Apple Inc.
- [piddnad/DDColor](https://github.com/piddnad/DDColor): Apache License 2.0.
- PyTorch, Core ML Tools, Hugging Face libraries and their dependencies, under their own licenses.

The Stable Diffusion inference in the app (CLIP tokenizer, DPM-Solver++ scheduler, the denoising loop) is this
app's own Swift code; Apple's ml-stable-diffusion is the reference implementation of the same model on Core ML.

## Apple's upscaling model

AI upscaling uses a model that macOS itself downloads and manages; it isn't distributed with this app.

## Test images

The photos in [TestImages](TestImages) were generated for this project with Stable Diffusion 1.5 on a Mac; they
show no real people or places. The other test files there were made by script. They're covered by this
repository's license.
