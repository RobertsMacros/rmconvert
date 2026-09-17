# rmconvert

A local macOS file converter by Roberts Macros. The app adds **Convert** and **PDF** to Finder’s right-click menu, with Roberts Macros branding.

**Status:** an early local-use build. Build 8 repairs the Finder-to-worker launch and adds native Services for cloud views. Its conversion engine has passed the [complete conversion matrix](docs/MATRIX_RESULTS.md): 54 source types and 330 source/action combinations. HDR gain-map photos convert to standard dynamic range (SDR). Finder uses native system symbols with macOS’s enabled-label colour: opposing arrows for Convert and stacked pages for PDF. The full Roberts Macros logo remains in setup. See [validation and limitations](docs/VALIDATION.md).

## Using it

Select files in Finder, right-click, then choose a format under **Convert**. The menu only offers formats shared by the selection. Results appear beside the originals. Existing names receive a number suffix; originals are never replaced.

In iCloud views that omit the extension menus, use **Services → Convert…** or **Services → PDF…**. These provide the same choices in a native pop-up menu, then dispatch the selected operation to a background worker. The final Services choice-to-output check is pending; see the validation record.

Use **PDF** for:

- **Combine PDFs**: select two or more PDFs in the same folder. Pages follow numeric-aware filename order.
- **Combine into one PDF**: select two or more supported images in one folder.
- **Split into separate PDFs**: create a folder containing one PDF per page.
- **Extract pages… / Remove pages…**: select one PDF, inspect the preview and enter a range such as `1-3, 5, 8`. Extraction follows the entered order. Repeated pages are included once.
- **Rotate clockwise / anticlockwise**: rotate every page by 90 degrees in a new PDF.
- **Compress PDF**: perform structural compression and only keep the output when it is smaller.

PDF-to-image and PDF-to-text conversions live under **Convert**. Page images, audio tracks, workbook sheets and outputs with supporting assets receive their own sibling folders.

Open **rmconvert** in Applications to check Finder integration and installed converters, optionally enable completion notifications, or view the recent-job log. The setup window does not need to stay open. There is no permanent menu-bar app. Ordinary jobs do not open a setup window, Dock icon or modal error dialogue. Failures stay in the recent-job log; existing notification permission controls optional completion/failure notifications. PDF page selection still opens its requested picker.

## Formats and limits

This build contains 47 actions and 64 explicit routing rules. It covers common static images, Office documents, Markdown/HTML/EPUB, spreadsheets, structured data, audio/video and subtitles. See [the route table](docs/ROUTES.md) for the exact routes.

Conversion can change content that the destination cannot represent. Photoshop layers are flattened; animated images are rejected by static-image routes. JPEG uses a white background for transparency. Still images, including iPhone HEIC photos with HDR gain maps, are decoded to SDR using macOS Image I/O. Outputs do not retain the HDR gain map. Image ancillary metadata is not copied. Office and document layout depends on the source and installed fonts. PDF page tools create a new page document and do not preserve document outlines or signatures. Encrypted PDFs and interactive forms are rejected. Compression does not downsample images.

RAW camera files, OCR, PDF-to-Word, iWork formats and HDR-preserving export or custom HDR tone mapping are outside this build. The menus use filename types; the worker checks the actual contents after selection. Video containers preserve compatible streams and encode incompatible ones; unsupported subtitles, attachments or HDR transformations cause a clear error. Audio extraction produces one file per track. FLAC renders floating-point and higher-depth audio as integer PCM up to 24 bits. Ringtones use the first 40 seconds.

Files must be downloaded locally and the output folder must be writable. Finder attempts to pass selected file URLs through LaunchServices. If macOS refuses that hand-off, it sends only the validated private request and the worker uses its existing file permissions. Services pass the selection through the system pasteboard and open a separate worker. macOS may still require initial permission for protected locations; the app does not alter privacy controls. Finder integration has been exercised in a normal home folder. Coverage in every cloud provider, Finder search view and external volume, and persistence after a reboot, remain unverified.

## Build, install and remove

Built and tested on Apple silicon with Xcode 26.6. The app has ad hoc local signatures; this is not a notarised distribution package. It needs the macOS frameworks plus stable local installations of LibreOffice, FFmpeg/ffprobe, Pandoc, ImageMagick, qpdf, Poppler and Mike Farah yq. Install these dependencies before building the complete route set. It does not depend on Codex’s private runtime.

```sh
brew install ffmpeg pandoc imagemagick qpdf poppler yq
brew install --cask libreoffice
./script/build_and_run.sh --build-only
./script/install.sh
```

`script/build_and_run.sh` is the build/run entry point. Build staging is in `/private/tmp/rmconvert-build-<uid>` to avoid iCloud metadata interfering with signing. `outputs/rmconvert.zip` contains the built app; it does not bundle the shared converter installations. Quit setup windows and finish conversions before updating. The installer refuses to replace an app with active workers.

```sh
./script/uninstall.sh
```

The removal script disables the extension and moves the app to the Bin. It keeps converted files, logs, preferences and shared conversion tools.

## Terminal and Stream Deck

The installer creates `~/.local/bin/rmconvert`. Use that full path if the folder is not on your command search path.

```sh
~/.local/bin/rmconvert --to png -- "/path/to/picture.jpg"
~/.local/bin/rmconvert --action pdf.extract --pages '4,1-2' -- "/path/to/document.pdf"
~/.local/bin/rmconvert --action pdf.combine -- "/path/to/part 1.pdf" "/path/to/part 2.pdf"
~/.local/bin/rmconvert --targets-for -- "/path/to/document.pdf"
~/.local/bin/rmconvert --doctor
```

CLI output is JSON, with a short summary on standard error. Exit codes: 0 completed or skipped; 1 at least one file failed; 2 invalid request/configuration. Logs are individual JSON files in `~/Library/Logs/rmconvert`, retained for up to 30 days and 1,000 jobs. The app displays the latest 100.

An optional catalogue at `~/.config/rmconvert/manifest.json` replaces the bundled catalogue. Start from `Resources/manifest.json`, validate with `--validate`, then open the app and choose **Check converters** to refresh Finder. The extension caches that validated snapshot across restarts, tied to the bundled catalogue version. A custom route can use an existing adapter; new conversion behaviour requires implementation and tests.

## Verification

```sh
./script/test.sh
python3 tests/external_routes.py
python3 tests/images_and_batches.py
python3 tests/media_routes.py
python3 tests/office_layouts.py
```

Tests generate their own files under `/private/tmp`. They cover output collisions and unchanged originals, native image/PDF operations, document/data routes, media stream copying, a 200-document batch, damaged inputs, workbook sheets, slide images, timeouts and network denial. [the validation record](docs/VALIDATION.md) records the results and remaining integration checks.

## Implementation notes

[Finder integration handover](docs/FINDER_INTEGRATION.md) · [Specification](docs/SPECIFICATION.md) · [Icon proposals](docs/icon-proposals.png)

The repository contains source, generated test definitions and public documentation. Runtime logs, compiled app bundles, development-machine archives and original local Git history are not included.
