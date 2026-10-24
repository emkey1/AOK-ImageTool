# Developing AOK-ImageTool

The [README](README.md) is for people using the app, and the built-in Guide (Help ▸ AOK-ImageTool Guide, source
[ImageViewer/Help/guide.html](ImageViewer/Help/guide.html)) describes every feature. This is the developer's view.

## Building

Requires Xcode 27. Open `ImageViewer.xcodeproj` and press ⌘R, or:

```sh
xcodebuild -project ImageViewer.xcodeproj -scheme AOK-ImageTool -configuration Release -derivedDataPath build build
open build/Build/Products/Release/AOK-ImageTool.app
```

The app runs on macOS 15 and later; newer APIs are availability-gated and their frameworks weak-linked. It's built
for Apple silicon. Image Playground and the Foundation Models features need a Mac with Apple Intelligence turned on;
Generate and Colorize need their models (below).

Swift 5 language mode, with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: types are main-actor unless marked
`nonisolated`, as the background imaging and model code is.

## Project layout

```
ImageViewer/
  App/           App entry, menus & commands
  Model/         ViewerModel (folder, navigation, display), edits, file ops, keyboard
  Imaging/       Decoding, prefetch cache, thumbnails, Core Image edit renderer, writer, metadata, animations;
                 ImageModel.swift (the shared runner for the picture-in, picture-out Core ML models),
                 Sharpen.swift (Fix Blur: Restormer in tiles, GFPGAN on aligned faces)
    Fill/        Extend: content-aware fill (C engine, ContentAwareFill.c), generative fill
                 (StableDiffusion.swift: Core ML inpainting; GenerativeExtend.swift: windows, cache, model install);
                 Removal.swift (Remove and Change Objects: LaMa, Match Photo, Generate, recolor; patches in
                 RemovalStore, and Clone & Heal); Change.swift (reading Change Objects' instructions); Recolor.c; Heal.c;
                 Colorize.swift
  Canvas/        AppKit zoom/pan canvas (CALayer-backed, HDR), Live Text overlay
  Intelligence/  Vision services, Foundation Models describer/chat, folder index & search
  Views/         SwiftUI: window, toolbar, browser (grid/filmstrip/sidebar), inspector, tools, sheets
  Support/       Preferences, model downloads, updater, migration, Photos (PhotosLibrary: Open from Photos via
                 PhotoKit, Live Photos; PhotosRoundTrip: Edit With), debug self-test and screenshot scenes
  Help/          The Guide (guide.html + light/dark screenshots), shown by GuideWindowController
  AppIcon.icon   App icon (Icon Composer layers, in Foray's style)
scripts/
  make-icon.swift                Redraws AppIcon.icon: swift scripts/make-icon.swift [preview.png]
  convert-inpainting-model.sh    Builds the generative fill model from the official weights
  convert-colorize-model.sh      Builds the colorizing model (DDColor) from its official weights
  convert-removal-model.sh       Builds the object removal model (Big LaMa) from its weights
  convert-sharpen-models.sh      Builds Fix Blur's models (Restormer's two, GFPGAN) from their official weights
  make-test-images.swift         Makes the synthetic files in TestImages/
  archive.sh                     Archives and sends the app to be notarized
  make-dmg.sh, dmg-layout.swift  The installer (after AOK-Foray's)
TestImages/      Generated demo photos and format samples, for the self-test
```

The project uses Xcode's synchronized folder, so new files under `ImageViewer/` are picked up automatically.

**Why the fill engine is in C:** Swift's unoptimized Debug code runs tight pixel loops roughly 1,000× slower than Release, which would make Extend unusable when running from Xcode. C files are compiled with `-O3` in every configuration (`GCC_OPTIMIZATION_LEVEL = 3`; Swift stays debuggable). The engine is coarse-to-fine patch synthesis that copies real pixels, so fills stay sharp. It's followed by a gradient-domain (Poisson) blend, so skies and other smooth gradients join without seams. It avoids copying the main subject (found by Vision), except near the edges being extended.

## Models

The optional models aren't in the repository or the app. The app downloads them from this repository's
[`models-1` release](https://github.com/emkey1/AOK-ImageTool/releases/tag/models-1) (a prerelease, so the updater
never takes it for a new version of the app):

| Archive | Contents | License |
| --- | --- | --- |
| `AOK-SD15-Inpainting-Unet.zip`, `AOK-SD15-Inpainting-Other.zip` | Stable Diffusion 1.5 Inpainting for Core ML: the UNet; the text encoder, VAE encoder and decoder, tokenizer files | CreativeML Open RAIL-M (LICENSE.txt and NOTICE.txt inside) |
| `AOK-DDColor.zip` | DDColor large for Core ML | Apache 2.0 (LICENSE.txt and NOTICE.txt inside) |
| `AOK-LaMa.zip` | Big LaMa for Core ML (full precision, 800 × 800) | Apache 2.0 (LICENSE.txt and NOTICE.txt inside) |
| `AOK-Restormer.zip` | Restormer's motion and defocus deblurring for Core ML (half precision, 384 × 384 tiles) | MIT (LICENSE.txt and NOTICE.txt inside) |
| `AOK-GFPGAN.zip` | GFPGAN v1.4 for Core ML (full precision, 512 × 512 aligned faces) | Apache 2.0 with listed exceptions (LICENSE.txt and NOTICE.txt inside) |

Each archive's size and SHA-256 are in `Support/ModelDownloads.swift`; a download that doesn't match isn't installed.
Splitting Stable Diffusion in two keeps each file under GitHub's 2 GB limit per release asset.

To rebuild them from the official weights:

```sh
scripts/convert-inpainting-model.sh ~/Downloads/sd-inpainting --install
scripts/convert-colorize-model.sh ~/Downloads/ddcolor --install
scripts/convert-removal-model.sh ~/Downloads/lama --install
scripts/convert-sharpen-models.sh ~/Downloads/sharpen --install
```

Each script uses a throwaway Python environment inside the folder you name and pinned versions of the converters
(Apple's [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion), [DDColor](https://github.com/piddnad/DDColor)).
`--install` puts the result in `~/Library/Application Support/com.oneopa.AOK-ImageTool/Models`; without it, use
**Settings ▸ Editing ▸ More ▸ Install from Folder…**. To publish new archives, zip the installed folders (with the
model's LICENSE.txt and a NOTICE.txt), upload them to a new `models-N` prerelease, and update the URL, sizes and
checksums in `ModelDownloads.swift`.

## How a generated fill is made

The code is in `Imaging/Fill/`.

1. **Working size.** The canvas is worked on at the model's size (short side 512 px), in overlapping 512 × 512 windows along the long side. The window with the most of the photo in it goes first, and each later window builds on what's already there.
2. **Rough start and prompt.** Each window starts from a blurred content-aware fill instead of pure noise. This keeps the model continuing the photo instead of starting a new picture beside it. Unless the user types something, the prompt is Apple Intelligence's description of the photo's setting (`ImageDescriber.describeSetting`, cached per photo), which leaves out the people and the subject, so the model continues the place without painting a second subject.
3. **Our own inference loop** (`StableDiffusion.swift`). It covers the CLIP tokenizer, the 9-channel inpainting UNet with classifier-free guidance, and a DPM-Solver++ scheduler (20 steps). Apple's Swift package doesn't do inpainting.
4. **Second pass** (the final fill, after Done). The new area, plus a band just inside the photo's extended edges, is redrawn at up to twice the working size in overlapping 512 × 512 windows, image-to-image from the first pass (strength 0.3). Each window sees the original at that scale, so the new area gets texture at the photo's own scale instead of being an enlargement. Meanwhile the first pass shows as a draft.
5. **Seamless edges.** Each window, and then the final fill, gets a membrane (Laplace) seam blend in C (`iv_seam_blend`), so the new content meets the original without a color cast. The photo then cross-fades into the fill across the band (`ExtendFill.feather`) instead of sitting on it with a hard edge.
6. **Scanned prints.** A white or black margin on at least three sides, with the picture's straight edge inside it (`PhotoBorder`), means a print. Extend works from the picture inside, and the photo is drawn over the fill only there (`ExtendFill.content`), so the border is replaced too. Otherwise the model treats the print as an object and paints a scene around it.
7. **Final size.** The result is enlarged to the final canvas, with Apple's super resolution where it's available.

It runs on the GPU. On an M5 Mac, the preview of a 16:9 extension takes about 15–25 s and the second pass about as long again, and the first use after installing compiles the model for a few seconds more. The crop tool's preview and the final fill share one generation, so Done doesn't make it again. The loaded model (about 2.5 GB of memory) is released after a few idle minutes.

## How Remove Objects and Fix Blur work

**Remove Objects** (`Imaging/Fill/Removal.swift`, `Views/Editing/RemoveObjectsEditor.swift`). A mark (a brush stroke, a
circled area, or an object Vision finds under a click) is mapped back through the image's turns and flips onto the
decoded pixels, grown a little, and the area around it (at least 800 px, square where it can be) is filled: by LaMa at
800 × 800 with the rest of its square mirrored, by the C engine, or by Stable Diffusion painting a description. Only
what changed is kept, as a PNG patch with a soft edge (`RemovalStore`, an `EditState.removals` entry with its rect),
drawn first in the pipeline, so later crops, turns, Extend and adjustments keep it.

**Change Objects** is the same editor in `.change` mode, making the same patches. A click's object mask (Vision) or a
stroke is narrowed to the pixels near the clicked color (`ObjectRemover.selectByColor`, `iv_select_color` in
`Recolor.c`), on the picture as shown. The distance is in L\*a\*b\*: hue difference (scaled by chroma, as in CIE94)
and saturation (C\*/L\*, which shading hardly changes, and which keeps grays such as hair out of a colored shirt) count
most, lightness little; a contrast curve then makes clear matches fully in, since a soft selection leaves some old color.
The selection's masks are made with no color space (Core Image would otherwise linearize them as gray levels). The
instruction is read by `ChangeRequest.parse` (`Imaging/Fill/Change.swift`): ending on a known color name with no
pattern or material word next to it, it's a color, recolored by `iv_recolor`: the area's mean L\* moved to the
target's, each pixel keeping its offset (narrowed toward black or white, so dark targets don't crush shadows), with
the target's a\*b\* faded toward the ends. Outside the selection but in the object it was found in (`reach`, the whole
person clicked), and a few pixels past its edge, a pixel changes by how much it is the selection's color (its a\*b\*
projected onto the area's mean), so the old color showing between strands of hair, or blended into the edge, changes
too, while skin, hair and gray ground don't. Anything else goes to Stable Diffusion with `keepShape`: img2img at
strength 0.8 from the selection itself, recolored first to the first color the description names
(`ChangeRequest.tint`), since the model keeps the colors it starts from. Apple Intelligence was tried for reading
instructions and dropped: it got colors wrong ("teal-ish green" → blue) and called plaid shirts plain red. A change's
`Removal.opacity` is its strength.

**Clone & Heal** is the editor's `.clone` mode. A stroke (soft-edged) and the offset to where it copies from (set by the
first stroke after an ⌥-click, then kept, as Photoshop's Aligned does) are mapped onto the decoded pixels
(`ObjectRemover.sourcePoint` maps points as `sourceMask` maps masks), and `ObjectRemover.clone` makes the patch: Copy
takes the moved pixels as they are; Heal (`iv_heal` in `Heal.c`) solves Laplace's equation for the difference
between destination and source across the stroke, with the difference just outside it as the boundary (Gauss-Seidel
with over-relaxation, coarse to fine over a pyramid), and adds it to the source, so the copied detail meets its
surroundings without an edge. `-extendTest -clone <image> <out.png> <from x> <from y> <to x> <to y> <radius> [copy]`
paints a dab headlessly. `-extendTest -change <image> <out.png> <x> <y> "<instruction>"` runs it headlessly
(`MASK_OUT` saves the selection), and `-extendTest -interpret "<instruction>"…` shows how instructions are read.

**Fix Blur** (`Imaging/Sharpen.swift`, `Views/Sheets/FixBlurSheet.swift`). Restormer (Out of Focus or Camera Shake)
runs over the whole picture in 384 × 384 tiles that overlap by 48 px and fade into each other; a tile that comes back
far from its input keeps the original. For faces, Vision's landmarks (eyes, nose, mouth corners) are fitted to GFPGAN's
512 × 512 template with a least-squares similarity transform; the restored face is mapped back and blended in with soft
edges, as much as the strength says.

Conversions are checked against the original PyTorch models: LaMa and GFPGAN must run in full precision (half
precision gives noise or a flat color), Restormer is fine in half precision on the GPU but not on the Neural Engine, so
`ImageModel` runs on CPU and GPU. NAFNet was tried for camera shake and dropped (colored noise on some pictures, even
in its own code).

## Releasing

Releases follow AOK-Foray's pipeline:

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the project, and add the version to `CHANGELOG.md`.
2. In Xcode: the "AOK-ImageTool" scheme, **Product ▸ Archive**, then **Distribute App ▸ Direct Distribution**, which
   signs with Developer ID and notarizes. Wait for "Ready to distribute". (`scripts/archive.sh` does the same from
   the command line, with the account signed in to Xcode.)
3. `scripts/make-dmg.sh` exports the notarized app from the newest archive and makes `dist/AOK-ImageTool-x.y.z.dmg`
   and `dist/AOK-ImageTool.dmg` (the same file, for the permanent latest-version link).
4. `gh release create vx.y.z dist/AOK-ImageTool-x.y.z.dmg dist/AOK-ImageTool.dmg --notes-file <the changelog entry>`.

The app checks `https://api.github.com/repos/emkey1/AOK-ImageTool/releases/latest` once a day (`Support/Updater.swift`).
It installs an update only if the app in the DMG is `com.oneopa.AOK-ImageTool`, signed with the team's Developer ID
and notarized. `scripts/make-dmg.sh --build` makes a locally signed installer for testing the DMG itself.

## Self-test and debug switches (Debug builds)

Runs every non-UI pipeline headlessly against a folder of images and prints a pass/fail report:

```
xcodebuild -project ImageViewer.xcodeproj -scheme AOK-ImageTool -configuration Debug -derivedDataPath build build
build/Build/Products/Debug/AOK-ImageTool.app/Contents/MacOS/AOK-ImageTool -selfTest TestImages
```

The self-test uses its own temporary storage and restores any preferences it changes, so it's safe to run while you're using the app. It checks the generative fill's scheduler and noise every time, and runs a real generation when the model is installed. `-debugExtend` (Debug builds) opens the first image straight into the Crop tool extending to 16:9 (add `-debugGenerate` for Generate), for checking that UI.

The Guide's and the README's screenshots come from `-debugScene viewer|grid|adjust|intelligence|info|stacks|stack-open`, with `-debugAppearance light|dark` and `-debugWindowSize 1280x800`. Runs with any of these switches use temporary storage and never save preferences. The screenshots were taken with a copy of the app under its own bundle ID, so its recents and window positions stay apart from yours. The demo photos in them were generated by the app's own model.

In Debug builds, `AOK_MODELS_DIR` and `AOK_MODELS_URL` point the models folder and the model downloads somewhere else (for testing the downloader against a local server), and `-extendTest -download generative-fill|colorize` downloads and installs one headlessly. `AOK_SELFTEST_ONLY=remove|blur|quality|download` runs just those self-test sections (`download` fetches the LaMa, Restormer and GFPGAN archives from `AOK_MODELS_URL`). `-extendTest -fixBlur <image> <out.png> [focus|shake|none] [faces]` runs Fix Blur on one picture (with `SHAKE=<pixels>`, on a copy shaken first, to compare with the original).
