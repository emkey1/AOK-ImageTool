# Changelog

## Unreleased

- **Remove Objects** (Intelligence ▸ Remove Objects…, ⇧⌘X): paint over something, click it or circle it, and it's gone, filled in from what's around it. Three fills: **Erase** (LaMa, a model made for removing objects, a one-time 190 MB download in Settings), **Match Photo** (the photo's own texture, no download), and **Generate**, which paints what you describe in its place. Each removal is a step (⌘Z, Try Again, compare with the original); Done saves "Name (Retouched)", stacked on the original, or, with Settings ▸ Editing ▸ "Remove Objects makes a copy" off, keeps the removals as an edit.
- **Extend saves a copy:** Done in the Crop tool saves "Name (Extended)", stacked on the original, which stays as it was.
- **Copies or in place:** Settings ▸ Editing ▸ Copies chooses, for Upscale with AI, Colorize, Black & White and Extend, whether each makes a copy (the default) or changes the image itself, the way Save does (the original to the Trash, asking first if Save asks).
- **Paste a picture** (⌘V, or Edit ▸ Paste as New Image) as a new file in the folder: screenshots, pictures from the web or other apps, image files copied in Finder.
- **Edit photos from your Photos library:** File ▸ Open from Photos… (⇧⌘O). Save stores the edit in Photos (Revert to Original there undoes it; iCloud Photos syncs it), with its settings, so it opens with them again. Live Photos stay live: the edit applies to every frame. Copies you make are added to Photos as new photos. Photos' Image ▸ Edit With ▸ AOK-ImageTool works too, for stills.
- **Upscale with AI works on animations** (GIF, animated PNG, WebP, HEIC): every frame, with its timing and looping, saved as a GIF or, in full color, an animated PNG (Upscale ▸ Save Animation As). Turns, crops and color adjustments apply to every frame. The menu shows each scale's size, and leaves out any that would be too large.
- **Straighten in Adjust:** an angle slider with 1° and 0.1° buttons and Auto, without opening the crop tool; the corners turned out of the frame are cropped away.
- **Shot Quality and Best Shots include new copies:** in a folder you've analyzed, pictures added or changed later are analyzed by themselves (a stack shows its newest copy, which had no score, so the stack sank to the bottom of Best Shots). Shot Quality scores the shown picture on its own when the folder hasn't been analyzed.
- Copies made by Upscale, Colorize and Black & White show in the filmstrip as soon as they're saved, instead of after the new file is read back.

## 1.0.0

The first release.

- **Viewing:** every format macOS reads (HEIC, AVIF, JPEG XL, WebP, 30+ camera RAW formats, PDF, SVG and more), HDR,
  animations and multi-page files; arrow-key browsing with images decoded ahead of time; zoom, Lock Zoom, grid,
  filmstrip, full screen, slideshow, Live Text, and an Info panel with a histogram, camera data and a map.
- **Culling:** pick, reject and unflag as Finder color labels; filters; sorting by date taken or by Best Shots;
  Find Duplicates and Find Similar; Move Rejects to Trash (undoable).
- **Editing**, non-destructive and undoable, kept across relaunches until you save: light, color, detail and 13
  filters; crop, rotate and straighten (Auto levels the horizon or upright lines); Straighten Document; Save in the
  same format, keeping metadata, with the original moved to the Trash; Export with metadata control.
- **Extend:** a photo past its edges, with Match Photo (continues the photo's texture) or Generate (Stable Diffusion
  1.5 Inpainting on this Mac, continuing the setting Apple Intelligence describes); scanned prints' borders replaced.
- **Copies:** Black & White (darkroom filters and toning), Colorize (DDColor), Upscale with AI (2×–4×, tiled past
  1920 px) and Reimagine save copies that stack with their original in the filmstrip and grid.
- **Subjects and backgrounds:** Remove Background, Select Object, Copy Subject; a new background (a color, the
  original blurred, a picture, or one generated around the subject) with Match Lighting.
- **Apple Intelligence:** Describe (title, alt text, keywords, file name), Ask about a photo, content and text search,
  Read and Translate text.
- **Models** for Generate and Colorize download from Settings or when first used, checked before they're installed.
- **Updates** from GitHub Releases, checked daily (Check for Updates…, Help ▸ Release Notes).
- Settings, unsaved edits and installed models move over from the earlier "ImageViewer" builds.
