# Developing AOK-ImageTool

The [README](README.md) is for people using the app, and the built-in Guide (Help ▸ AOK-ImageTool Guide, source
[ImageViewer/Help/guide.html](ImageViewer/Help/guide.html)) describes every feature. This is the developer's view.

## Building

Requires Xcode 27. Open `ImageViewer.xcodeproj` and press ⌘R, or:

```sh
xcodebuild -project ImageViewer.xcodeproj -scheme AOK-ImageTool -configuration Release -derivedDataPath build build
open build/Build/Products/Release/AOK-ImageTool.app
```

The app runs on macOS 15 and later; newer APIs are availability-gated and their frameworks weak-linked. Image
Playground and the Foundation Models features need a Mac with Apple Intelligence turned on; Generate, Colorize, Fix
Blur and Erase need their models (below).

The release is a universal build (Apple silicon and Intel), and the README and Guide say the app runs on both. The
image models are Apple silicon only: `GenerativeModel.isSupported` is `#if arch(arm64)`, and everything that needs a
model checks it, to leave the feature out or say what it needs (Settings shows “Needs a Mac with Apple silicon”). AI
upscaling asks VideoToolbox (`SuperResolution.isSupported`) and is hidden where that says no.

There's no Intel Mac to test on, so the Intel half is checked under Rosetta, in the macOS 15 VM (first with 1.4.0).
An Intel-only Debug build (add `ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO` to the build line; Debug otherwise builds only the
Mac's own architecture) passes the self-test there with the same 311 checks (as of 1.5.0) as the Apple silicon build
run without models (`AOK_MODELS_DIR` pointing at an empty folder), and `open --arch x86_64 -a AOK-ImageTool.app` runs
a release as Intel code to look at. That exercises the Intel code and the “needs Apple silicon” paths; it says nothing about Intel
graphics or how fast a real Intel Mac is.

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
    Stitch/      Stitch Pictures: Stitch.c (corners, matching, RANSAC homography, the two-band renderer),
                 Stitch.swift (how the pictures lie on each other, leveling, the view), StitchFill.swift (crop, fills)
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

**Corrected programs.** Half precision can't hold some of the normalization arithmetic: squares over 256 overflow in the
Stable Diffusion VAEs' group norms, and Restormer's attention sums 147,456 of them. What that does depends on how Core ML
runs the program. macOS 15's CPU really computes it, so the VAEs give flat gray and generated pictures come out as a blur;
any Mac's CPU gets Restormer's colors wrong. The app therefore carries corrected programs (`Support/ModelFixes/`, made by
`scripts/fix-model-programs.py`) that do that arithmetic at full precision, with the same weights, and `Support/ModelFix.swift`
puts each in place of the `model.mil` it was made for just before the model loads, so nothing has to be downloaded again.
A new conversion has a different program, which is left alone: run the script on it and update the checksums in `ModelFix.swift`.

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

A patch is put together with straight alpha (`ObjectRemover.patch`: its color in 8 bits, and how much of it shows
beside it), never faded out by Core Image into 8 premultiplied bits. Premultiplied, a color has one or two levels left
where the patch has all but faded out, and an HDR photo's patch is in its PQ color space, where the step from one
level to the next is then from black to the brightest there is: every soft edge came back with a thin bright line
around it (the self-test paints an HDR picture with itself and checks nothing changes).

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

**New Image from Description** (`GenerativeImage.picture` and `.finished`, `NewImageSheet` in `Views/Sheets/GenerateSheets.swift`)
paints from nothing with the inpainting model: a canvas with nothing known, at 512 on its short side, painted in Extend's
overlapping windows (`GenerativeExtend.paint`, strength 1, 20 steps), so wide shapes stay one scene. The one kept is
drawn at twice the size and painted again lightly (Extend's refine settings); only that pass's fine detail is kept, over
the preview's own broad color and light (both blurred by 6 px, the difference added back), since each window of a light
repaint drifts a little in color and would show as a seam. Then super resolution takes it to 2048 px. The prompt is
"a high quality photo of …" unless the description names another kind of picture. `-extendTest -create
"<description>" <square|landscape|portrait|wide> <out-prefix> [seed]` (with `PREVIEWS=n` to time several) runs it.

**White balance** (`Imaging/WhiteBalance.swift`) is Warmth and Tint, applied by `CITemperatureAndTint` right after
Auto enhance. The filter is a 3 × 3 matrix in linear light, so both helpers search it rather than model it. The
eyedropper averages a small spot of the picture as white balance sees it (`EditRenderer.whiteBalanceInput`: turned,
straightened and auto-enhanced, uncropped; the click is mapped through the crop) and finds, coarse to fine, the
setting that makes it gray. On a face (Vision's face boxes) it aims for natural skin instead: in log red/green and
blue/green, typical skin is 0.70 from gray at −25° (the ColorChecker's light and dark skin, cheeks in real photos), and
skin within an ellipse around it (0.22 along, 0.17 across) is left alone; skin outside is brought inside it, further in
the further off it was (a cast is likelier than skin at the very edge of natural). Auto scores settings on a grid by how much of a 112 px copy they make nearly gray
(brighter pixels counting more), times a prior for changing less (σ 0.55 for Warmth, 0.35 for Tint), and gives up
when the best makes less than 3% gray. Starting from the photo's average color (gray world) was tried and dropped:
it took the color out of sunsets and autumn scenes. `-extendTest -whiteBalance <image>…` prints what Auto does to
each image as it is and with a warm or cool cast put in (`WB_OUT` saves before/after pictures).

**Clone & Heal** is the editor's `.clone` mode. A stroke (soft-edged) and the offset to where it copies from (set by the
first stroke after an ⌥-click, then kept, as Photoshop's Aligned does) are mapped onto the decoded pixels
(`ObjectRemover.sourcePoint` maps points as `sourceMask` maps masks), and `ObjectRemover.clone` makes the patch: Copy
takes the moved pixels as they are; Heal (`iv_heal` in `Heal.c`) solves Laplace's equation for the difference
between destination and source across the stroke, with the difference just outside it as the boundary (Gauss-Seidel
with over-relaxation, coarse to fine over a pyramid), and adds it to the source, so the copied detail meets its
surroundings without an edge. `-extendTest -clone <image> <out.png> <from x> <from y> <to x> <to y> <radius> [copy] [hdr]`
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

## How Stitch Pictures works

`Imaging/Stitch/` (`Stitch.c`, `Stitch.swift`, `StitchFill.swift`), `Views/Sheets/StitchSheet.swift`,
`Model/ViewerModel+Stitch.swift`. No model and no outside library: it runs on Intel and macOS 15.

**Why not Vision.** `VNHomographicImageRegistrationRequest` is exact (under 0.2 px) only while two frames differ by up
to about 2% of their width; at 4% it's off, beyond that its answer is meaningless, and it reports confidence 1 either
way. `VNTranslationalImageRegistrationRequest` finds big shifts but knows nothing of perspective. Stitching needs
pictures that share a quarter to a half of themselves, so the matching is our own.

1. **Corners** (`iv_stitch_features`). Harris corners at up to 2,400 px (`Stitch.workingSide`), the strongest three in
   each cell of a grid (44 cells along the long side) so they're spread over the picture, placed between pixels by a parabola through the
   peak. Each is described by 256 brightness comparisons around it (BRIEF), turned to the corner's own direction, so a
   camera rolled a little still matches. Nothing makes them match across zooms.
2. **Pairs** (`iv_stitch_align`). Every picture against every other: corners that are each other's nearest (Hamming
   distance) and clearly nearer than the runner-up are paired; RANSAC finds the homography most pairs agree on (within
   2.5 px), refit by least squares on the centered, scaled points. A pair counts as overlapping with at least 20
   agreeing corners, a tenth of those paired, and a homography that keeps the overlap the right way round and about the
   same size (`plausible`; not judged at the picture's corners, which with a wide lens can be behind the other
   picture's camera). The median brightness ratio at the agreeing corners is the pair's gain.
3. **Layout** (`Stitch.layout`). The surest links make a spanning tree over the biggest set of pictures joined to each
   other; the picture fewest links from the furthest one is the middle one, and every other picture's homography onto
   it is the product along the tree. (No bundle adjustment: fine for a handful of pictures, and it would drift round a
   full circle.) Homographies are kept scaled to determinant 1, which also fixes their sign: a direction is in front of
   a camera exactly when its third coordinate comes out positive. Gains are chained the same way and centered on their
   geometric mean.
4. **The view.** The pictures are looked at from one view, a rotation of the middle picture's camera: ahead is where
   the cameras look between them; down is what the files say (an iPhone writes its motion sensor's reading in its maker
   note, key 8: gravity along the phone's axes, which `Stitch.down` turns into the picture's own directions for the
   back camera, if the picture hasn't been turned here; of the four ways round a picture can be shown, it's the one
   with down nearest the picture's bottom, which is how the camera turned it, so a picture saved again with its turn
   applied reads right too) or, failing that, the normal of
   the plane the cameras' left-to-right directions lie in (a panned camera keeps its sides level), when they turned at
   least a dozen degrees and that normal is within 40° of down in every picture. The two agree to about 3° on real
   pairs. Without either, or when the pictures look more than 50° up or down, the view is as the middle picture was
   taken, from between them. The rotations come from the homographies and the lens
   (the 35 mm equivalent focal length in EXIF); pictures without one (scans) are joined flat on the middle picture's
   plane, where the lens cancels out. Level, Tilt and Turn are a further rotation of the view.
5. **Shape.** A direction of the view goes to the picture's pixels as a flat (rectilinear) view, a cylinder or a
   sphere (`view_ray` and `view_point` in the C). Automatic is flat up to 80° across and tall, a cylinder up to 95°
   tall, a sphere beyond. A flat view shows nothing more than 72° off its middle; what's cut is reported (`trimmed`).
6. **Blending** (`iv_stitch_render`). Two bands. Each picture has a small blurred copy (256 px, `iv_stitch_low`): its
   broad light and color, which cross-fade over the whole overlap by each picture's distance from its own edge, hiding
   what's left of exposure differences. The rest (the picture minus that) is its detail, taken by that weight to the
   16th power, which is nearly all from one picture at a time: nothing is blurred by being averaged, and something that
   moved between pictures shows once. Sampling is Catmull-Rom for the saved picture, bilinear for previews; rows are
   rendered in parallel. Everything is 8 bits in the first picture's color space, standard range (HDR photos are
   opened without HDR, as Combine does).
7. **Edges.** `iv_stitch_covered_rect` finds the largest covered rectangle (the histogram method) for Crop. Fill
   renders the view at up to 2,048 px, fills it with the content-aware engine or with `GenerativeExtend.paint` in
   Extend's two passes (from masks rather than a rectangle), seam-blends it to the pictures, and `Stitch.filled` puts
   the full-size stitched picture back over it, fading into it just inside the pictures' edges.
8. **Saving.** The sheet works on pictures of 2,400 px; `saveStitched` opens them again at full size and renders with
   the layout the sheet found (homographies are kept in full-size pixels). A result past 16,384 px or 120 megapixels is
   made smaller, its pictures opened smaller to match.

On an M-series Mac, two 24-megapixel photos line up in about 0.2 s, preview in 0.02 s and render at full size (33
megapixels) in under half a second; two 48-megapixel ones make 97 megapixels in about 2 s. A generated fill takes about
a minute.

**Trying it.** `-extendTest -stitch <out folder> <automatic|flat|cylinder|sphere> <crop|match|generate|none> <image>…`
stitches files as the sheet and Save do and writes each stage (`LOOK=level,tilt,turn`, `SIDE=n` to hold the size
down); `AOK_STITCH_TRACE=1` prints each pair's counts and the two estimates of down. The self-test's views
(`StitchViews`) are made by Core Image from one picture as a turning camera would see it, so the true homography is
known and the stitched picture can be compared with a single wide view. `-debugScene stitch` opens the sheet on three
such views, and `-debugStitch flat,fill,match,tilt=4` sets its choices.

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

Debug builds have their own bundle ID (`com.oneopa.AOK-ImageTool.debug`), so their settings never mix with an installed
copy's: the self-test turns off things like moving originals to the Trash while it runs, and a run that's interrupted
can't put them back (the next run starts from the defaults). It refuses to run under the released ID. Installed models are still shared (and so get their
corrected programs, as they would from the app).

Runs every non-UI pipeline headlessly against a folder of images and prints a pass/fail report:

```
xcodebuild -project ImageViewer.xcodeproj -scheme AOK-ImageTool -configuration Debug -derivedDataPath build build
build/Build/Products/Debug/AOK-ImageTool.app/Contents/MacOS/AOK-ImageTool -selfTest TestImages
```

The self-test uses its own temporary storage and restores any preferences it changes, so it's safe to run while you're using the app. It checks the generative fill's scheduler and noise every time, and runs a real generation when the model is installed. `-debugExtend` (Debug builds) opens the first image straight into the Crop tool extending to 16:9 (add `-debugGenerate` for Generate), for checking that UI.

The Guide's and the README's screenshots come from `-debugScene viewer|grid|adjust|adjust-object|presets|pictureonly|intelligence|info|stack-open|remove|change|clone|fixblur|blackwhite|newimage|stitch` (`adjust-object` selects the picture's subject and adjusts it on its own; `presets` saves two presets in the run's temporary storage and puts the first on the picture; `pictureonly` is F's full screen as far as a window in the background can show it, with the toolbar, sidebar, inspector and filmstrip put away and the picture on black, but the window left a window). The tool scenes set the tool part way through on particular demo photos (`showSceneForGuide` in `RemoveObjectsEditor`: the boat in Sailboat outlined, the apple in Fruit Bowl selected with "green" typed, a Clone & Heal stroke over Desert Canyon's shrubs); `newimage` opens New Image from Description and paints its previews; `stack-open` wants a folder with a stack in it. They're captured with `screencapture -l` of the window (with its sheet, for the sheets), with `-debugAppearance light|dark` and `-debugWindowSize 1280x800`. Runs with any of these switches use temporary storage and never save preferences. The screenshots were taken with a copy of the app under its own bundle ID, so its recents and window positions stay apart from yours. The demo photos in them were generated by the app's own model.

In Debug builds, `AOK_MODELS_DIR` and `AOK_MODELS_URL` point the models folder and the model downloads somewhere else (for testing the downloader against a local server), and `-extendTest -download generative-fill|colorize` downloads and installs one headlessly. `AOK_SELFTEST_ONLY=remove|change|clone|wb|local|presets|fullscreen|newimage|blur|quality|tags|combine|stitch|straighten|places|download` runs just those self-test sections (`local`: objects adjusted on their own; `presets`: saved presets, their file and applying them; `fullscreen`: what F puts away and brings back, without a window) (`remove` also runs `change`; `download` fetches the LaMa, Restormer and GFPGAN archives from `AOK_MODELS_URL`). `AOK_SELFTEST_LIVE=1` adds checks that ask Apple Maps and Wikipedia themselves (`places`). `-extendTest -fixBlur <image> <out.png> [focus|shake|none] [faces]` runs Fix Blur on one picture (with `SHAKE=<pixels>`, on a copy shaken first, to compare with the original).

**Full screen (F)** hides the toolbar with the window's own `NSToolbar.isVisible`, not SwiftUI's `.toolbar(.hidden, for: .windowToolbar)`: on macOS 27 the SwiftUI modifier empties the toolbar but keeps its height, which would leave a blank band across the top of the screen. The self-test covers the model's side; the window's side (really going full screen, a window that was already full screen, F during a slideshow, the pointer at the top of the screen) is checked by hand in the macOS 15 VM, where plain keys like F pass through VNC.

`-debugKeys <folder>` (Debug builds) checks the keyboard shortcuts: it presses them as if typed and checks what each did (rotating, rating, Rename, the filmstrip, holding M, ⌘↓, Option on the Rotate button), checks that no two menu items share keys, writes `keytest.txt` and pictures of the toolbar to the folder, and quits. It brings its window forward, so run it in the macOS 15 VM (open it with a copy of a picture; the rating keys write to the file), and click its window if it opens behind another. VNC passes neither ⌘ nor ⌥, which is why it's done this way: menu shortcuts are sent as system keyboard events through the app's own queue, after bringing SwiftUI's menus up to date as a real key press does.
