# AOK-ImageTool

A fast, keyboard-first image viewer and editor for macOS 15 and later: browse, cull, edit, extend photos past their edges, cut out subjects, and use Apple's on-device intelligence where the system has it.

**Help ▸ AOK-ImageTool Guide** (⌘?) is the user manual, with screenshots; its source is [ImageViewer/Help/guide.html](ImageViewer/Help/guide.html). This README is the developer's view.

Open `ImageViewer.xcodeproj` in Xcode 27 and press ⌘R. From the command line:

```
xcodebuild -project ImageViewer.xcodeproj -scheme ImageViewer -configuration Release -derivedDataPath build build
open build/Build/Products/Release/AOK-ImageTool.app
```

## Viewing

- **Formats:** everything ImageIO reads (JPEG, PNG, HEIC/HEIF, AVIF, JPEG XL, WebP, TIFF, GIF, BMP, PSD, OpenEXR, DDS, KTX, TGA, ICO/ICNS, DICOM, and 30+ camera RAW formats), plus PDF and SVG.
- **Arrow keys browse the folder** (← → and ↑ ↓; Space / ⇧Space; Home / End). Trackpad swipes and the mouse wheel also step through images when the whole image is visible.
- **Instant navigation.** Decoded neighbors are prefetched in the direction you're moving. During key-repeat, thumbnails appear immediately and full decoding waits until you pause. RAW files show their embedded preview first.
- **Rendering:** EXIF orientation, HDR photos in HDR on EDR displays, animated GIF/APNG/WebP/HEICS playback, multi-page TIFF and PDF (Page Up/Down).
- **Zoom & pan:** GPU zoom (pinch, ⌘/⌥+scroll at the pointer, double-click to toggle fit/100%), drag to pan. **Lock Zoom (L)** keeps the same zoom and position across images, which is useful for comparing burst shots.
- **Small images:** View ▸ **Enlarge Small Images to Fit Window** (⌥⌘9) scales them up to fill the window, and **Sharpen Enlarged Images with AI** shows them through Apple's on-device upscaler instead of plain smoothing.
- **Views:** grid view (G), filmstrip (T), folder sidebar, full screen (F), slideshow (S), and an Info inspector with histogram, camera data and a map for GPS-tagged photos.
- **Live Text & Visual Look Up** directly on the image.

## Culling

- **P / X / U** — Pick / Reject / Unflag. Flags are stored as Finder color labels (green / red), so they show up in Finder too.
- Filter to Picks / Rejects / Unflagged; **Move Rejects to Trash** in one step. Trash is undoable (⌘Z).
- Sort by name, dates (including EXIF date taken), size, kind, shuffle, or **Best Shots (AI)**.
- Go ▸ Next / Previous Folder (⌥⌘→ / ⌥⌘←) walks sibling folders, such as date-named photo folders.
- Each folder remembers the last image you viewed.

## Editing (non-destructive, undoable)

- Rotate / flip, **Crop & Straighten** (C) with aspect presets and rule-of-thirds guides.
- **Extend** (in the Crop tool): drag the frame up to 35% past the photo's edges, or pick an aspect such as 16:9 to widen a photo to that shape. Fill the new area one of two ways, with a live preview and **Try Again** for a different result:
  - **Match Photo** continues the photo's own texture (content-aware fill). It's fast and always available.
  - **Generate** draws new content with Stable Diffusion 1.5 Inpainting, running on this Mac (Apple silicon). Optionally describe what to add, such as “sandy beach and blue sky”; leave it empty to continue the scene. Needs the model; see [Generative fill model](#generative-fill-model).

  Your original pixels stay untouched, and later adjustments apply to the extended area too.
- Light (exposure, brightness, contrast, highlights, shadows), color (saturation, vibrance, warmth, tint), detail (sharpness, noise reduction, vignette), Auto Enhance, and 13 filter looks with live previews.
- **Black & White** with darkroom filters (red, orange, yellow, green, blue: a channel mix in linear light) and sepia, warm or cool toning.
- Show Original (\\) for before/after comparison.
- **Save (⌘S)** writes back in the same format and keeps metadata. By default the original goes to the Trash so it's always recoverable.
- **Export (⇧⌘E)** to JPEG/HEIC/AVIF/PNG/TIFF/GIF/BMP/JPEG 2000 with quality, max size and **metadata control (strip location for sharing)**. Exporting from the grid selection batch-exports many images at once.

## Apple Intelligence & Vision (all on-device)

| Feature | Powered by |
| --- | --- |
| Describe image (title, alt-text caption, keywords, suggested file name) | Foundation Models (macOS 26+; it looks at the pixels on macOS 27, and works from Vision's labels and text on macOS 26) |
| Ask questions about the image (chat) | Foundation Models |
| Rename with an AI-suggested name; add keywords as Finder tags (Spotlight-searchable) | Foundation Models |
| **Content search** in the toolbar: “owl”, “beach”, or text inside images; related words when there's no exact match | Vision classification + OCR, NaturalLanguage embeddings |
| Best-shot ranking, screenshot/document detection | Vision aesthetics |
| Find Similar / Find Duplicates (with “keep best of each group”) | Vision feature prints |
| Remove Background, Copy Subject | Vision foreground instance masks |
| **Select Object…**: click any object to select it, ⌥-click to exclude, then cut out, copy or save as PNG | Vision interactive segmentation (macOS 27; on 15 and 26, click picks the foreground object under the pointer) |
| **New background** behind a cutout: a color, the original blurred, a picture, or one made in Image Playground (Intelligence ▸ Background). **Match Lighting** blends the subject's brightness, light color and edges with a picture background | Core Image, ImagePlayground |
| **Upscale with AI** (Image menu, 2×, 3× or 4×): saves a sharper, larger copy; images over 1920 × 1920 (the model's limit per pass) go through in overlapping tiles | VideoToolbox super resolution (macOS 26+; Apple's model, one-time download) |
| **Extend ▸ Generate**: new content past the photo's edges | Core ML: Stable Diffusion 1.5 Inpainting (user-installed model, Apple silicon) |
| **Colorize**: black and white photos to color, saved as a copy; only the color is the model's (its a*b* on the photo's own L*) | Core ML: DDColor large (user-installed, `scripts/convert-colorize-model.sh`, Apache 2.0) |
| **Background ▸ Generate on This Mac**: a scene painted around a cutout, from the scene you describe and the subject Apple Intelligence describes | The same model, inpainting everything but the subject; Foundation Models for the subject's description |
| Auto Straighten, Smart Crop, Straighten Document | Vision horizon, saliency, document detection |
| Reimagine in Image Playground | ImagePlayground (macOS 15.1+) |
| Read & translate text in images | Vision OCR + Translation |

Folder analysis is cached in `~/Library/Caches/com.oneopa.AOK-ImageTool/Index`, so each folder is only analyzed once.

### What works on which macOS

Everything not listed here works on macOS 15 and later. That includes viewing, culling, editing, Extend (both fills), Live Text, translation, and all the Vision features: search, best shots, duplicates, background removal, horizon, Smart Crop and documents. Features a system can't run are hidden or explained rather than failing.

| Feature | macOS 15 | 15.1+ | 26 | 27 |
| --- | --- | --- | --- | --- |
| Image Playground (Reimagine, generated backgrounds) | — | ✓¹ | ✓¹ | ✓¹ |
| Describe / Ask / AI rename & keywords | — | — | ✓¹ (from Vision's labels) | ✓¹ (looks at the image) |
| Upscale with AI, Sharpen Enlarged Images with AI | — | — | ✓ | ✓ |
| Select Object refinement (click and ⌥-click to refine) | foreground object under the click | same | same | ✓ |
| HDR display | ✓ (extended range) | ✓ | ✓ | ✓ |

¹ Needs a Mac with Apple Intelligence turned on.

### Generative fill model

Extend ▸ Generate uses [Stable Diffusion 1.5 Inpainting](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting) (CreativeML Open RAIL-M license), converted to Core ML. The app doesn't ship the model (about 2 GB). Build it once from the official weights:

```
scripts/convert-inpainting-model.sh ~/Downloads/sd-inpainting --install
```

The script uses a throwaway Python environment inside that folder, Apple's [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) converter at a pinned commit, and the fp16 weights (no safety checker). It takes a few minutes. `--install` copies the result to `~/Library/Application Support/com.oneopa.AOK-ImageTool/Models/StableDiffusionInpainting`. Without `--install`, choose the `Resources` folder it made in **Settings ▸ Editing ▸ Install from Folder…**, which also shows the model's status and can remove it. Delete the work folder afterwards.

How a generated fill is made (`Imaging/Fill/`):

1. **Working size.** The canvas is worked on at the model's size (short side 512 px), in overlapping 512 × 512 windows along the long side. The window with the most of the photo in it goes first, and each later window builds on what's already there.
2. **Rough start and prompt.** Each window starts from a blurred content-aware fill instead of pure noise. This keeps the model continuing the photo instead of starting a new picture beside it. Unless the user types something, the prompt is Apple Intelligence's description of the photo's setting (`ImageDescriber.describeSetting`, cached per photo), which leaves out the people and the subject, so the model continues the place without painting a second subject.
3. **Our own inference loop** (`StableDiffusion.swift`). It covers the CLIP tokenizer, the 9-channel inpainting UNet with classifier-free guidance, and a DPM-Solver++ scheduler (20 steps). Apple's Swift package doesn't do inpainting.
4. **Second pass** (the final fill, after Done). The new area, plus a band just inside the photo's extended edges, is redrawn at up to twice the working size in overlapping 512 × 512 windows, image-to-image from the first pass (strength ~0.35). Each window sees the original at that scale, so the new area gets texture at the photo's own scale instead of being an enlargement. Meanwhile the first pass shows as a draft.
5. **Seamless edges.** Each window, and then the final fill, gets a membrane (Laplace) seam blend in C (`iv_seam_blend`), so the new content meets the original without a color cast. The photo then cross-fades into the fill across the band (`ExtendFill.feather`) instead of sitting on it with a hard edge.
6. **Scanned prints.** A white or black margin on at least three sides, with the picture's straight edge inside it (`PhotoBorder`), means a print. Extend works from the picture inside, and the photo is drawn over the fill only there (`ExtendFill.content`), so the border is replaced too. Otherwise the model treats the print as an object and paints a scene around it.
7. **Final size.** The result is enlarged to the final canvas, with Apple's super resolution where it's available.

It runs on the GPU. On an M5 Mac, the preview of a 16:9 extension takes about 15–25 s and the second pass about as long again, and the first use after installing compiles the model for a few seconds more. The crop tool's preview and the final fill share one generation, so Done doesn't make it again. The loaded model (about 2.5 GB of memory) is released after a few idle minutes.

## Keyboard

Press **?** in the app for the full list. The essentials:

| Key | Action |
| --- | --- |
| ← → ↑ ↓, Space | Previous / next image |
| Z, 0, 1, + − | Fit/100% toggle, fit, 100%, zoom |
| G / T / F / S | Grid / filmstrip / full screen / slideshow |
| I / E / A | Info / Adjust / Intelligence panel |
| P / X / U | Pick / Reject / Unflag |
| R, ⇧R, C, \\ | Rotate, crop, before/after |
| ⌘S, ⇧⌘E, ⌘⌫ | Save, Export, Move to Trash |
| ⇧⌘D, ⌥⌘B | Describe image, Remove background |

Single-key shortcuts go through a window-scoped key monitor rather than menu key equivalents, so they never steal typing from the search or chat fields. Press Esc in an empty field to return focus to the image.

## Project layout

```
ImageViewer/
  App/           App entry, menus & commands
  Model/         ViewerModel (folder, navigation, display), edits, file ops, keyboard
  Imaging/       Decoding, prefetch cache, thumbnails, Core Image edit renderer, writer, metadata
    Fill/        Extend: content-aware fill (C engine, ContentAwareFill.c), generative fill
                 (StableDiffusion.swift: Core ML inpainting; GenerativeExtend.swift: windows, cache, model install)
  Canvas/        AppKit zoom/pan canvas (CALayer-backed, HDR), Live Text overlay
  Intelligence/  Vision services, Foundation Models describer/chat, folder index & search
  Views/         SwiftUI: window, toolbar, browser (grid/filmstrip/sidebar), inspector, tools, sheets
  Support/       Preferences, supported formats, debug self-test and screenshot scenes
  Help/          The Guide (guide.html + light/dark screenshots), shown by GuideWindowController
  AppIcon.icon   App icon (Icon Composer layers, in Foray's style)
scripts/
  make-icon.swift                Redraws AppIcon.icon: swift scripts/make-icon.swift [preview.png]
  convert-inpainting-model.sh    Builds the generative fill model from the official weights
  convert-colorize-model.sh      Builds the colorizing model (DDColor) from its official weights
```

The project uses Xcode's synchronized folder, so new files under `ImageViewer/` are picked up automatically.

**Why the fill engine is in C:** Swift's unoptimized Debug code runs tight pixel loops roughly 1,000× slower than Release, which would make Extend unusable when running from Xcode. C files are compiled with `-O3` in every configuration (`GCC_OPTIMIZATION_LEVEL = 3`; Swift stays debuggable). The engine is coarse-to-fine patch synthesis that copies real pixels, so fills stay sharp. It's followed by a gradient-domain (Poisson) blend, so skies and other smooth gradients join without seams. It avoids copying the main subject (found by Vision), except near the edges being extended.

## Self-test (Debug builds)

Runs every non-UI pipeline headlessly against a folder of images and prints a pass/fail report:

```
build/Build/Products/Debug/AOK-ImageTool.app/Contents/MacOS/AOK-ImageTool -selfTest /path/to/images
```

The self-test uses its own temporary storage and restores any preferences it changes, so it's safe to run while you're using the app. It checks the generative fill's scheduler and noise every time, and runs a real generation when the model is installed. `-debugExtend` (Debug builds) opens the first image straight into the Crop tool extending to 16:9 (add `-debugGenerate` for Generate), for checking that UI.

The Guide's screenshots come from `-debugScene viewer|grid|adjust|intelligence|info`, with `-debugAppearance light|dark` and `-debugWindowSize 1280x800`. Runs with any of these switches use temporary storage and never save preferences. The screenshots were taken with a copy of the app under its own bundle ID, so its recents and window positions stay apart from yours. The demo photos in them were generated by the app's own model.

Requirements: macOS 15 or later (built with Xcode 27; newer APIs are availability-gated and their frameworks weak-linked). Image Playground and the Foundation Models features need an Apple Intelligence–capable Mac with Apple Intelligence turned on. Generate needs Apple silicon and the model above.
