# Roberts Macros artwork

`RobertsMacros.png` contains the Roberts Macros brand artwork displayed in the setup window and, small, in the footer of the Organise pages window.

## App icon

`AppIcon.iconset` holds the app icon at every size macOS uses (16 to 1024 pixels). `script/make_icon.py` generates it from `RobertsMacros.png`: the RM monogram, without the tagline (unreadable at Dock sizes), in the logo's own blue (RGB 63, 91, 116) on a white rounded square on Apple's 1024-point icon grid, with a soft shadow. No new brand colour is introduced. The build converts the iconset to `AppIcon.icns` with `iconutil`; `Info.plist` names it in `CFBundleIconFile`, and the app also sets it as the running application's icon when the setup or Organise pages window brings it into the Dock.

Finder menus use native SF Symbols: `arrow.left.arrow.right` for Convert and `doc.on.doc` for PDF. Build 5 draws each symbol into transparent 1× and 2× images, then applies `labelColor` once using source-in compositing. Template tinting is disabled so Finder receives the resolved colour. Images are cached and regenerated on the next menu opening if the extension’s effective appearance changes.

Build 3 removed the original black rectangle. Build 4’s secondary-label palette remained visibly too dim in the user’s Finder screenshot. Its rendering check showed opacity of approximately 0.25 in light mode and 0.30 in dark mode: the palette’s translucent colour was effectively applied twice. Build 5 uses the enabled-label colour, with measured maximum opacity of approximately 0.85 after secure image archiving at both resolutions in light and dark appearances.

These checks establish image colour, resolution and transparency. They do not establish exact matching to Finder’s vibrancy or highlighted-menu appearance; those require inspection of the actual Finder menu.
