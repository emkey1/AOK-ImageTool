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
  Imaging/       Decoding, prefetch cache, thumbnails, Core Image edit renderer, writer, metadata
    Fill/        Extend: content-aware fill (C engine, ContentAwareFill.c), generative fill
                 (StableDiffusion.swift: Core ML inpainting; GenerativeExtend.swift: windows, cache, model install)
  Canvas/        AppKit zoom/pan canvas (CALayer-backed, HDR), Live Text overlay
  Intelligence/  Vision services, Foundation Models describer/chat, folder index & search
  Views/         SwiftUI: window, toolbar, browser (grid/filmstrip/sidebar), inspector, tools, sheets
  Support/       Preferences, model downloads, updater, migration, debug self-test and screenshot scenes
  Help/          The Guide (guide.html + light/dark screenshots), shown by GuideWindowController
  AppIcon.icon   App icon (Icon Composer layers, in Foray's style)
scripts/
  make-icon.swift                Redraws AppIcon.icon: swift scripts/make-icon.swift [preview.png]
  convert-inpainting-model.sh    Builds the generative fill model from the official weights
  convert-colorize-model.sh      Builds the colorizing model (DDColor) from its official weights
  convert-removal-model.sh       Builds the object removal model (Big LaMa) from its weights
  make-test-images.swift         Makes the synthetic files in TestImages/
  archive.sh                     Archives and sends the app to be notarized
  make-dmg.sh, dmg-layout.swift  The installer (after AOK-Foray's)
TestImages/      Generated demo photos and format samples, for the self-test
```

The project uses Xcode's synchronized folder, so new files under `ImageViewer/` are picked up automatically.

**Why the fill engine is in C:** Swift's unoptimized Debug code runs tight pixel loops roughly 1,000× slower than Release, which would make Extend unusable when running from Xcode. C files are compiled with `-O3` in every configuration (`GCC_OPTIMIZATION_LEVEL = 3`; Swift stays debuggable). The engine is coarse-to-fine patch synthesis that copies real pixels, so fills stay sharp. It's followed by a gradient-domain (Poisson) blend, so skies and other smooth gradients join without seams. It avoids copying the main subject (found by Vision), except near the edges being extended.

## Models

The three optional models aren't in the repository or the app. The app downloads them from this repository's
[`models-1` release](https://github.com/emkey1/AOK-ImageTool/releases/tag/models-1) (a prerelease, so the updater
never takes it for a new version of the app):

| Archive | Contents | License |
| --- | --- | --- |
| `AOK-SD15-Inpainting-Unet.zip`, `AOK-SD15-Inpainting-Other.zip` | Stable Diffusion 1.5 Inpainting for Core ML: the UNet; the text encoder, VAE encoder and decoder, tokenizer files | CreativeML Open RAIL-M (LICENSE.txt and NOTICE.txt inside) |
| `AOK-DDColor.zip` | DDColor large for Core ML | Apache 2.0 (LICENSE.txt and NOTICE.txt inside) |
| `AOK-LaMa.zip` | Big LaMa for Core ML (full precision, 800 × 800) | Apache 2.0 (LICENSE.txt and NOTICE.txt inside) |

Each archive's size and SHA-256 are in `Support/ModelDownloads.swift`; a download that doesn't match isn't installed.
Splitting Stable Diffusion in two keeps each file under GitHub's 2 GB limit per release asset.

To rebuild them from the official weights:

```sh
scripts/convert-inpainting-model.sh ~/Downloads/sd-inpainting --install
scripts/convert-colorize-model.sh ~/Downloads/ddcolor --install
scripts/convert-removal-model.sh ~/Downloads/lama --install
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

In Debug builds, `AOK_MODELS_DIR` and `AOK_MODELS_URL` point the models folder and the model downloads somewhere else (for testing the downloader against a local server), and `-extendTest -download generative-fill|colorize` downloads and installs one headlessly.
