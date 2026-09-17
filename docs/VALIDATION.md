# rmconvert validation record

15 September 2026 · Apple silicon · macOS 27.0 (26A5425a) · app 0.1.0, build 2.

## Automated conversion checks (build 2)

**172 checks passed** across five suites, using generated files. These are representative behaviour checks, not proof that every possible document, codec or camera format converts correctly.

| Suite | Passed | Evidence |
|---|---:|---|
| Native/core | 47 | PNG/JPEG/TIFF/HEIC/PDF; PDF combine, split, ordered extraction, removal and rotation; invalid ranges, encryption/forms/corruption; untouched originals; 16 simultaneous colliding publications; menu intersections; timeout child termination; permission-denied network connection |
| Documents/data/PDF backends | 61 | Office and Pandoc pipelines, RTFD, CSV/TSV quoting and strings, formula-like cells, workbook CSV, YAML/TOML, flat XML mapping, plist values, PDF text/raster/compression and source hashes |
| Images and batching | 23 | WebP/AVIF/ICNS/ICO, SVG dimensions, PSD composite, animated-image rejection, XML mapping/rejection, local HTML, 200 Office files, independent qpdf validation of all 200 PDFs, corrupt-input isolation and unchanged originals |
| Media | 35 | Multiple audio streams retained, AAC packets copied, VP9/Opus fallback, per-track extraction, PCM/FLAC sample round trip, GIF, ringtone, subtitle text and no-audio rejection |
| Office layouts | 6 | Visible/hidden/empty sheet CSV exports, normal visible-sheet PDF handling, one PNG per presentation slide and raster dimensions matching the PDF export at 300 dpi |

The 200-document run completed in **30.4 seconds** on this Mac, using batches of 20. This is a measurement for small generated documents, not a timing promise for arbitrary files. All 200 PDFs passed `qpdf --check` and all sources were unchanged. Invalid DOCX package detection was added after LibreOffice accepted a deliberately corrupt DOCX as plain text; the corrected mixed good/bad batch passed.

The final 500-file menu benchmark measured **3.10 ms median / 3.67 ms p95** across 100 runs. It measures the shared menu resolver, not the entire Finder UI response.

The slide fixture exported using LibreOffice’s interpreted page style. The test verifies that raster dimensions match that PDF, rather than claiming arbitrary source layout fidelity from a synthetic fixture. Complex presentation/Office layout comparison remains outstanding.

The native test fixture for an intentionally malformed PDF emits a Core Graphics diagnostic. The suite handles that rejection and exits successfully.

## Build 3 icon replacement

After the build 2 tests, a user reported that the Finder logo appeared as a black box. Build 3 removes the custom bitmap renderer and uses native monochrome system symbols for Convert and PDF. The updated app and extension built, signed, installed and registered successfully. Both icons retained a visible glyph and predominantly transparent pixels after secure image archiving. The Finder menu entries were inspected through accessibility, but the tool still could not return a Finder screenshot; the user subsequently confirmed the glyphs appeared but found the black tint too strong. The 172 conversion checks above describe the preceding build; this icon-only change did not rerun those suites.

## Build 4 icon colour

The symbols now use a `secondaryLabelColor` palette with template tinting disabled. The same securely archived images were rendered in light and dark appearances: both retained predominantly transparent backgrounds, with translucent black glyphs in light mode and translucent white glyphs in dark mode. This confirms adaptive colour rather than a fixed black bitmap. Finder’s exact colour matching and highlighted-state appearance still require visual confirmation; the UI tool cannot capture Finder screenshots. Build 4 built and installed successfully, passed strict signature verification and catalogue validation (47 actions, 64 routes), and registered exactly one installed Finder extension. The Mac was locked during the subsequent UI check, so that check could not proceed. Conversion code is unchanged, so the earlier 172 conversion checks were not repeated.

## Build 5 icon colour correction

The user’s screenshot established that build 4 still looked too dim beside Finder’s own icons. Its palette-rendered glyph opacity was approximately 0.25 in light mode and 0.30 in dark mode. Build 5 uses the enabled-label colour and applies it once to transparent bitmap representations, avoiding that compounded opacity. The same archive/restore checks passed for both icons at 1× and 2× in light and dark appearances: maximum opacity was 0.84–0.85, the glyph colour was black/white respectively, the background remained predominantly transparent, and both image resolutions survived archiving. The extension regenerates cached images when its effective appearance changes. Build 5 built and installed successfully, passed strict signature and catalogue validation (47 actions, 64 routes), and registered one installed extension. The refreshed Convert menu was present in Finder’s accessibility tree. Finder screenshots remained unavailable. These are rendering checks, not proof of matching Finder’s composited appearance or selected state.

## Build 6 HDR photo conversion

17 September 2026: the worker no longer rejects still images solely because they contain Apple or ISO HDR gain maps. It explicitly requests Image I/O’s SDR rendition, applies orientation and writes a new output without the gain map. Floating-point output, single-frame and pixel-limit guards remain in place.

**74 core checks passed**, including 27 new HDR regression checks using a synthetic, non-photographic HEIC fixture. These cover gain-map presence, JPEG/PNG/TIFF/PDF conversion, SDR colour agreement, dimensions, integer pixels, SDR headroom, absent output gain maps, EXIF orientation and an unchanged source. The earlier external-backend suites were not rerun for this decoder change.

The two real HEIC photos from the reported failure were retried with the installed build. Both produced 3024×4032, 8-bit SDR JPEGs. Source SHA-256 hashes were unchanged. Independent thumbnail comparisons against macOS’s oriented SDR decode measured mean channel differences of 4.66 and 4.84 on a 0–255 scale. This checks colour consistency; it is not a visual review of every pixel. Neither the photos nor their filenames, paths or job logs are included in this repository.

Build, catalogue validation (47 actions, 64 routes), installation and strict signature verification passed; the installed bundle reports build 6.

## Build 7 compatibility and background operation

The [full matrix](MATRIX_RESULTS.md) covers all 54 advertised source types and 330 source/action pairs: 304 successful conversions, 26 correct same-format skips, no remaining failures. Every case uses synthetic files; validators cover image dimensions, media stream presence and decoding, document/package structure, PDF structure and preserved text, and unchanged source hashes. FLAC conversions now accept ordinary floating-point decoders and render up to 24-bit integer PCM. PDFKit page-operation outputs are normalised and checked with qpdf when available.

All **206 regression checks passed**: 74 core, 61 external, 23 image/batch, 42 media and 6 Office layout checks. This includes the 200-document batch, invalid-input isolation, original preservation, HDR photos and numerical FLAC quantisation checks. The core suite was repeated after the PDF repair. All seven normalised filename aliases (JPEG, TIF, AIF, HEIF, YML, HTM and MARKDOWN) also completed representative conversions with the installed app.

The installed app’s actual document-open handler completed one successful and one deliberately failing job. Both workers logged `visibleWindows=0` and accessory activation policy at start and finish. Selected input URLs were sent alongside the private request; their temporary access scopes are balanced at termination. This test completed without an access prompt in the test folder. It does not prove the absence of prompts in every protected location. No privacy controls or permissions were bypassed. The later direct Finder check found a launch failure that this test did not cover; see the build 8 correction below.

## Build 8 direct Finder check and cloud fallback

After unlocking the Mac, an actual Finder action exposed a build 7 regression: sending selected URLs from the sandboxed extension failed with `NSCocoaErrorDomain` 256. Build 8 retries the private request alone if it is still present. A real local-folder JPEG-to-PNG menu action then succeeded, created a numbered output beside the existing output, and logged zero visible worker windows with accessory activation throughout. No access dialogue appeared in that test.

Finder's iCloud-backed Documents view did not display Finder Sync menus. Explicit registration of cloud roots did not change that, so the ineffective root change was removed. Two native Services, **Convert…** and **PDF…**, are now installed as the alternative entry points. Both entries were observed in the actual iCloud Finder context menu. The public Services API accepted a generated-file request, called the provider and opened its choice menu. The provider reported accessory activation; the choice menu waited for activation before tracking.

**The final Services choice-to-output interaction is still awaiting manual confirmation.** The UI automation could inspect Finder's entries but did not successfully activate them, and timed out when inspecting the service's accessory-app menu. No claim is made that this final interaction or exact icon appearance has been visually verified.

Four installed-app background checks passed: successful and deliberately invalid images from the app-owned request folder, plus success and failure through the extension request-only fallback. All four logged zero visible worker windows and accessory activation at start and finish. A separate request-only PDF rotation produced a new PDF that passed `qpdf --check`; the original hash was unchanged. These are launch-handler tests, not additional Finder menu clicks. Strict bundle signature and catalogue validation passed. The 330-case matrix and 206 regression results above apply to the unchanged conversion engine from build 7; those full suites were not repeated for menu/launch changes.

## Real app and Finder checks

- Built and signed the CLI, process helper, Finder extension and containing app; strict signature verification passed.
- Installed at `/Applications/rmconvert.app`; active catalogue contains 47 actions and 64 routing rules.
- All configured stable converter dependencies are present. No private Codex runtime is used.
- Finder shows one **Convert** and one **PDF** menu. Earlier duplicate extension processes were cleared; the final menu inspection showed no duplicates.
- The original Roberts Macros image is included in both extension and app resources. Build 2 assigned the template logo to both real Finder menu parent items; builds 3–4 supersede it with native system symbols. The setup window, including the full logo, was visually inspected. Finder menu screenshots were unavailable, so the menu-icon pixels themselves were not visually verified.
- A real Finder JPEG-to-PNG conversion succeeded on a filename containing an apostrophe, ampersand, accents, spaces and an emoji. The original was unchanged.
- Native **Extract pages…** preview was inspected and used. Entering `4,1-2` created a three-page PDF containing Page 4, Page 1 and Page 2 in that order. The original was unchanged.
- With the setup app closed and no app worker running, Finder **Rotate clockwise** launched the worker and created a new PDF. Independent inspection found four pages, each rotated 90 degrees.
- The final setup-only close/update guard succeeded after app launch completed. It refuses to replace an app while workers/page windows remain active, or while setup is still starting.
- Shell syntax checks passed for build, install, uninstall and test entry points. The uninstall script was inspected but not executed on the delivered installation.

## Outstanding acceptance checks

Reboot persistence has not been tested; the Mac was not rebooted. Notification permission/delivery/click behaviour has not been exercised. Full Finder coverage in protected folders, cloud-provider views, search results and external volumes has not been established. Ordinary local home-folder operation has been demonstrated.

No claim is made that every advertised source codec or every complex Office/PDF feature has a representative fixture. RAW camera support and the fixed A4/20 mm default page template are not implemented in this build. The exact policies and exclusions are recorded in [the specification](SPECIFICATION.md) and [README](../README.md).
