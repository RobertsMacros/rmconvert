# rmconvert v2.3: implemented specification

Updated 15 September 2026. This replaces the earlier proposal and duplicated build prompt with the actual implementation contract. This document describes the implemented product and remaining acceptance checks.

## Interaction

The native Finder Sync extension supplies two top-level contextual menus: **Convert** and **PDF**. Both use the original Roberts Macros mark included with the application. The full logo appears in the setup window. Finder controls the surrounding menu appearance and placement.

**Convert** offers the intersection of explicitly configured formats for the selected files. Aliases are normalised. Files already in the chosen format are skipped; an all-current ordinary target is disabled where configured. One-to-many outputs receive a sibling folder. Missing backends remove affected routes. An incompatible selection receives a disabled explanatory child rather than an empty menu.

**PDF** is separate from format conversion. It offers combine, split, extract, remove, clockwise/anticlockwise rotation and structural compression when applicable. Combine needs at least two eligible files in the same folder and uses numeric-aware filename order. Extract/remove operate on one PDF and open a native preview with a validated page-range field. Extraction preserves the user’s range order and removes duplicate page selections. Removing every page is rejected. All operations create new output.

The setup app shows Finder extension status, converter availability, notification opt-in and a readable recent-job log. Routine conversions do not open the setup window. A worker error can open an alert when notifications have not been authorised. There is no permanent menu-bar icon or custom file browser.

## Architecture

The app contains an AppKit setup/worker executable, a Finder Sync extension, a Swift command-line executable and a small process-group launcher. They use the shared Swift catalogue and conversion engine. The catalogue uses schema version 3 with distinct action IDs, explicit source routes, priorities and backend requirements. The exact delivered rules are in `Resources/manifest.json` and the generated route table [the route table](ROUTES.md).

The Finder menu callback only uses an in-memory catalogue and captured URLs. It performs no conversion, subprocess execution or directory scan. Route eligibility is computed once per distinct source type, rather than repeatedly for every selected file.

Finder proxies menu items across processes, so each item carries an integer tag mapped to its captured immutable job request. On a click, the extension writes a UUID-named JSON request in its private container with owner-only permissions. LaunchServices opens that request with a new containing-app worker. Arguments passed through `NSWorkspace.OpenConfiguration` were unsuitable because the caller is sandboxed; document-open delivery was demonstrated on this Mac.

The worker checks the request’s canonical directory, UUID name, owner, file type and size, consumes the request, then revalidates the action and source files. It runs outside the extension sandbox, subject to ordinary macOS file permissions. The app does not require an App Group or a registered XPC/Mach service.

The app publishes validated catalogue/capability snapshots using distributed notifications. The extension stores the last snapshot in its own preferences, tied to the bundled catalogue bytes, and loads it outside the callback. A new bundled catalogue invalidates the previous cache. Custom catalogues live at `~/.config/rmconvert/manifest.json`; **Check converters** republishes changes.

## Execution and output contract

Original files are never replaced. Each operation writes into a private temporary directory beside the source, validates the result, then publishes with macOS exclusive atomic rename. Existing files or folders receive a numeric suffix. Partial batch failures keep successful outputs and report failures individually. Temporary files are removed on normal completion and handled errors; a forcibly terminated app can leave a hidden staging directory.

Inputs are canonicalised before processing. Actual system folders and app-bundle contents are excluded. Cloud placeholders must be downloaded. Ordinary folders are rejected, with RTFD as the explicit document-package exception.

At most four jobs run concurrently. LibreOffice is serialised and FFmpeg has two slots. Eligible Office inputs are grouped by folder and document family in batches of at most 20. Duplicate output stems are separated to avoid LibreOffice collisions. Office package inputs are checked before launching the backend so invalid DOCX/XLSX/ODF files are not silently treated as plain text. A bad input does not prevent good batch members from completing.

External converters run in separate process groups with bounded timeouts. Timeout handling terminates the group, including surviving children. Backend output is captured in temporary files; diagnostic reads are bounded. Internet and local TCP/IP connections are denied by the backend sandbox profile; local Unix sockets remain available for LibreOffice’s internal IPC. No runtime tools, fonts, templates or models are downloaded. LibreOffice receives a fresh profile with macros and link updates restricted. Documents requiring remote assets are rejected.

Per-job JSON logs contain action, input/output paths, success/skip/failure and route-specific details. Keep up to 1,000 jobs for 30 days. The app displays the latest 100 with clickable output paths. Notification clicks open the recent-job log; exact single-job navigation is not implemented.

## Conversion policies

| Family | Delivered behaviour |
|---|---|
| Static images | Native JPEG/PNG/TIFF/HEIC; ImageMagick WebP/AVIF/ICO; native sizing plus iconutil ICNS. Apply orientation, preserve a supported decoded colour space, reject floating-point/HDR gain maps. Maximum 120 megapixels. JPEG converts to 8-bit sRGB on white at quality 0.95; HEIC uses 0.90 and rejects input depth above 8 bits. Ancillary metadata is not copied. |
| Photoshop / animation | Use a readable PSD composite and report layer flattening. Ordinary raster routes reject multiple frames/pages. No RAW camera routes are advertised. |
| SVG | Reject active content and unsupported external references. Render at twice nominal width with a minimum width of 1,024 pixels, maintaining aspect ratio and bounded dimensions. PDF output is rasterised. |
| Image PDF | One image per page without pixel resampling; use plausible source DPI, otherwise 144 DPI. Multi-image combine uses filename order. This is decoded image embedding, not a guarantee of original compressed JPEG packet copying. |
| PDF | Native PDFKit page operations; reject encrypted or form-containing documents and more than 5,000 pages. Page content is copied into a new document; document-level outlines, metadata and signatures are not guaranteed to survive. Poppler produces every page at 300 dpi, or extracts existing text without OCR. qpdf performs structural compression and only publishes a smaller result. |
| Office | LibreOffice PDF export uses its normal document/page/print handling and installed fonts. Font substitution and exact layout preservation are not automatically proven for arbitrary documents. Slide images use Office-to-PDF-to-Poppler. |
| Text and ebooks | textutil or Pandoc as configured. Markdown/HTML with assets get a dedicated output folder with relative references. Markdown/HTML/EPUB-to-PDF uses Pandoc ODT followed by LibreOffice. The current build uses converter defaults for documents without a page style; the earlier explicit A4/20 mm template proposal is not implemented. |
| Workbooks | One UTF-8 CSV per sheet, including hidden and empty sheets, using displayed values. PDF follows normal visible-sheet print handling. CSV/TSV imports explicitly preserve strings, including leading zeros and formula-like content. |
| Tables and structured data | UTF-8, strict headers and rectangular CSV/TSV, quoted multiline support. JSON-to-CSV accepts flat record arrays with sorted union headers; missing/null values become empty cells. YAML/TOML mappings reject unsupported tags and unrepresentable values. Native plist XML/binary conversion preserves values. |
| XML | JSON-to-XML accepts a flat object with scalar values or scalar arrays under a root wrapper. XML-to-JSON retains the root, represents attributes as `@name`, keeps leaf text as strings and groups repeated elements into ordered arrays. Mixed content, namespaces, DTDs and entities are rejected. This is an explicit mapping, not a universal lossless XML/JSON round trip. |
| Media | Probe all streams. Copy compatible video/audio streams and encode incompatible ones to the target’s configured codec. Preserve supported streams and chapters; reject content the target cannot preserve. Logs record actual copied/encoded counts. HDR transcoding requiring a tone-map decision is rejected. |
| Audio / GIF / subtitles | One file per audio track for extraction. WAV/AIFF preserve supported PCM depth/rate/channels; FLAC supports integer samples up to 24 bits. MP3 uses 320 kbit/s; AAC M4A uses 256 kbit/s where re-encoding is needed. Ringtone is the first 40 seconds. GIF uses a palette, 15 fps, maximum width 640 and no audio. Subtitle conversion preserves text/timing and records styling loss. |

For large structured data, additional input/output and node/depth limits apply; exceeding a limit causes an error rather than truncated published data. Routes are explicit and cannot be discovered by chaining unrelated converters.

## Build and delivery

The implementation is a shell-built native Swift/AppKit project. `script/build_and_run.sh` is the single build/run entry point. The build stages locally in `/private/tmp` to avoid iCloud metadata invalidating signatures, signs inside-out with ad hoc signatures, verifies the app and extension, validates the catalogue and creates `outputs/rmconvert.zip`.

`script/install.sh` installs `/Applications/rmconvert.app`, registers/enables the extension, creates `~/.local/bin/rmconvert` and opens setup. It requires any active job/page window to finish first. `script/uninstall.sh` disables the extension and moves the app to the Bin while retaining outputs and shared dependencies.

This is a local Apple silicon build, not a notarised release for arbitrary Macs. Stable converter installations are external dependencies. Their checked versions are in [the validation record](VALIDATION.md). Source, scripts, tests, branding and documentation are included in this repository.

## Acceptance and remaining work

The app was built, signed and installed on the development Mac. Real Finder jobs have exercised image conversion, native page extraction and a PDF rotation with the setup app closed. Both separate menus are present without duplicate entries. The branded setup window was visually inspected; Finder menu screenshots are unavailable through the current UI tool, so menu-image pixels were not visually inspected despite the image being assigned to both actual menu items. A subsequent user report identified a black rectangle in Finder. The renderer remains unfixed; the proposed replacement symbols are not installed.

Automated verification covers native conversions, unchanged originals, concurrent output collisions, document/data and media routes, a 200-document Office batch, corrupt inputs, hidden/empty sheets, slide rasterisation, network denial and process timeouts. See [the validation record](VALIDATION.md) for measured results.

Remaining acceptance checks are reboot persistence, notification delivery/click behaviour, all protected/cloud/search/external Finder locations, and representative complex Office/PDF layouts. They do not prevent use of the tested installed app. They must not be described as passed. RAW camera support and the fixed A4/20 mm document template remain deferred features rather than advertised routes.
