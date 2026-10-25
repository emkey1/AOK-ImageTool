# Changelog

## Unreleased

- **New Image from Description** (File ▸ New Image from Description…, ⇧⌘N, or the Intelligence panel's Create section): describe a picture and choose a shape (Square, 3:2, 2:3, 16:9); four previews are painted on this Mac, one after another, with Stable Diffusion; keep as many as you like (⌘-click or a preview's circle chooses several, and a double-click on one of them keeps them all; the sheet stays open, and previews still to be painted wait): each is painted again at twice the size for detail (keeping the preview's color and light, so its windows don't show) and enlarged to 2048 px, then saved as a new image named after the description. Illustration, Animation or Sketch… hands the description to Image Playground instead.
- **Star ratings**: 1–5 rate (the same number again adds a half star), 0 takes it off; or click the stars in the Info panel, or right-click ▸ Rating. Written where other apps read them: the file's own XMP for JPEG, HEIC, PNG and TIFF (only the metadata is rewritten, never the picture; its Finder label and unsaved edits are kept), a sidecar “.xmp” for camera RAW, DNG and other formats (keeping what Lightroom has in it). Ratings show on thumbnails; Sort & Filter shows ★ or more and sorts by rating. The 0 and 1 keys no longer zoom (⌘9 fits, ⌘0 is 100%, Z toggles).
- **Copy and Paste Edits** (Edit menu, ⇧⌘C / ⇧⌘V, or right-click): one picture's light, color, detail, white balance and filter onto the selected pictures, in any window; each keeps its own crop, turn and retouching, and the paste is one step to undo. Copy Subject moves to ⌥⇧⌘C.
- **Save in File** (Intelligence panel ▸ Describe): the title, caption (also as alt text) and keywords written into the file's metadata (a sidecar for RAW), for Spotlight, Photos and Lightroom.
- **Reopen windows from last time** (Settings ▸ General, on): the windows open at quit come back at launch, each at its folder, picture and place.
- **Windows**: each window remembers its folder and picture, and comes back at them when macOS reopens windows (after ⌥⌘Q or a restart, or always with “Close windows when quitting an application” off); they came back empty. With more than one window open, each one's subtitle (and its Window menu item) starts with its folder. Two windows on the same folder show the same edits (saving in one used to leave the other holding edits already in the file); closing one only asks about edits the other doesn't have, and quitting counts each edited image once. File ▸ Open in New Window… (⌥⌘O, ⌥ in the File menu) and ⌥ in Open Recent open in a new window. A picture or folder opened from Finder that a window already shows brings that window to the front instead of the front window switching folders.
- Change Objects' selection shows on any color: tinted blue, with a white line between dark edges (the pink tint vanished on red things, and the line was under a point wide).
- The Guide's pictures are all new, with more of them: Remove, Change, Clone & Heal, Fix Blur, Black & White, the Info panel and New Image.

## 1.1.0

- **Remove Objects** (Intelligence ▸ Remove Objects…, ⇧⌘X): zoom in (pinch, ⌘-scroll, ⌘+/⌘−/⌘0) to mark small things; paint over something, click it or circle it, and it's gone, filled in from what's around it. Three fills: **Erase** (LaMa, a model made for removing objects, a one-time 190 MB download in Settings), **Match Photo** (the photo's own texture, no download), and **Generate**, which paints what you describe in its place. Each removal is a step (⌘Z, Try Again, compare with the original); Done saves "Name (Retouched)", stacked on the original, or, with Settings ▸ Editing ▸ "Remove Objects makes a copy" off, keeps the removals as an edit.
- **Change Objects** (Intelligence ▸ Change Objects…, ⇧⌘J): click or paint what to change and say what it should be. A color ("blue", "make her dress dark green") is changed in place, keeping its folds and shading; anything more ("a red plaid flannel shirt", "a leather jacket") is painted over it by the generative model, keeping its shape and starting from the color it names. A click takes the part of the object that's the color clicked (the shirt, not the person); ⌥ takes away from the selection. Return remakes the last change from new words, Try Again paints it differently, Strength sets how much shows; Done saves "Name (Changed)", stacked on the original (Settings ▸ Editing ▸ "Change Objects makes a copy").
- **White Balance** in the Adjust panel: an eyedropper (click something that should be white or gray; click a face and it's balanced for natural skin instead), Auto (the setting that turns the most of the photo neutral, leaving a photo with nothing neutral in it alone), Lit By presets (Shade, Overcast, Indoor Lamps, Fluorescent, As Shot), and the Warmth and Tint sliders, moved here from Color.
- **Clone & Heal** (Image ▸ Clone & Heal…, ⇧⌘H, or Heal in the Adjust panel): ⌥-click where to copy from and paint where it goes, with a crosshair on the source and a live preview of what's copied. Heal (the default) keeps the copied detail in the color and light where it goes, blended without an edge (a gradient-domain blend, solved in C); Copy copies it as it is. The offset stays for later strokes until the next ⌥-click. Each stroke is a step; Done saves "Name (Retouched)", stacked (Settings ▸ Editing ▸ "Clone & Heal makes a copy").
- **Extend saves a copy:** Done in the Crop tool saves "Name (Extended)", stacked on the original, which stays as it was.
- **Extend after a crop starts from the crop:** the cropped picture is saved first ("Name (Cropped)", stacked) and Extend opens on it, instead of bringing back what was cropped away.
- **Copies or in place:** Settings ▸ Editing ▸ Copies chooses, for Upscale with AI, Colorize, Black & White, Fix Blur, Extend, Remove Objects, Change Objects and Clone & Heal, whether each makes a copy (the default) or changes the image itself, the way Save does (the original to the Trash, asking first if Save asks).
- **Paste a picture** (⌘V, or Edit ▸ Paste as New Image) as a new file in the folder: screenshots, pictures from the web or other apps, image files copied in Finder.
- **Import from Photos** (File ▸ Import from Photos…): copies photos out of the library into a folder as ordinary files, offering the folder imported into last (or Choose Folder… for another), and opens it.
- **Edit photos from your Photos library:** File ▸ Open from Photos… (⇧⌘O). Save stores the edit in Photos (Revert to Original there undoes it; iCloud Photos syncs it), with its settings, so it opens with them again. Live Photos stay live: the edit applies to every frame. Copies you make are added to Photos as new photos. Photos' Image ▸ Edit With ▸ AOK-ImageTool works too, for stills.
- **Upscale with AI works on animations** (GIF, animated PNG, WebP, HEIC): every frame, with its timing and looping, saved as a GIF or, in full color, an animated PNG (Upscale ▸ Save Animation As). Turns, crops and color adjustments apply to every frame. The menu shows each scale's size, and leaves out any that would be too large.
- **Fix Blur** (Image ▸ Fix Blur…): sharpens a blurry photo into a stacked "Name (Sharpened)" copy. Out of Focus or Camera Shake (Restormer) and Restore Faces (GFPGAN), each with a strength, previewed before and after on a detail at full size; on this Mac, with two optional downloads in Settings (about 100 MB and 315 MB). Settings ▸ Editing ▸ Copies can have it sharpen the image itself.
- Features that use an optional model stay visible before it's installed (Generate a Background, Generative Extend and Colorize in the Intelligence panel, Extend's and Remove Objects' fills), and choosing one explains what it needs and offers the download.
- **Straighten in Adjust:** an angle slider with 1° and 0.1° buttons and Auto, without opening the crop tool; the corners turned out of the frame are cropped away.
- **Unsaved edits are easy to find and clear:** View ▸ Show ▸ Edited Images lists them; File ▸ Revert All Edited Images… takes them all off (undoable); quitting names the images and offers Show Them, and the reminder can be turned off for edits that are kept anyway (Settings ▸ Editing). Edits that can't show (a slider a hair off zero, a crop of the whole picture) no longer count as edits, so an image isn't "edited" with nothing to see.
- **Double-click** a stack to spread it out (in the filmstrip, again to close it). Double-clicking the picture goes to full resolution at the spot clicked, and back to the zoom you had, fitted or not.
- **A stack shows the copy you viewed or made last**, also after the folder is opened again or the app relaunched; a copy made while you're on another picture goes on top of its stack.
- **Shot Quality and Best Shots include new copies:** in a folder you've analyzed, pictures added or changed later are analyzed by themselves (a stack shows its newest copy, which had no score, so the stack sank to the bottom of Best Shots). Shot Quality scores the shown picture on its own when the folder hasn't been analyzed.
- Fixed on macOS 15: masks read back at most sizes came out empty there (macOS 15's Core Image skips one-byte-per-pixel rows that aren't a multiple of 4 bytes), which could make Extend and Generate a Background ignore what they should keep, and the new retouching tools say nothing was marked.
- Fixed a crash while editing an HDR photo (seen while straightening): macOS's Live Text analysis read past the end of the decoded photo while the edit preview read it too. Live Text and subject detection now get a plain copy of their own.
- A fitted picture is all in view: it no longer reaches under the filmstrip (the canvas left room for the toolbar it was already below, pushing the picture down).
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
