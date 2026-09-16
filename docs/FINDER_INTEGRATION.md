# Finder integration handover: lessons from rmconvert

15 September 2026. This is a record of the approach, failures and verified results from building rmconvert on the development Mac. It is not an implementation of the proposed iCloud filer. Filing rules, watched folders, destination layout and background automation have not been designed or built here.

## What we actually built

rmconvert is a native macOS app containing a **Finder Sync extension**, an AppKit setup/worker app and a Swift CLI sharing the same engine. The extension adds **Convert** and **PDF** directly to Finder’s contextual menu. The containing app performs the work and can start when the user clicks an action even if setup is closed.

This distinction matters: we did **not** build an Automator workflow or an action inside Finder’s existing **Quick Actions** submenu. If that existing submenu is sufficient for the filer, consider a Shortcut, Automator Quick Action or native Action Extension instead of assuming our full architecture is necessary. Apple documents native Action Extensions as another route into Quick Actions. [Apple: Finder Action Extensions](https://developer.apple.com/documentation/appkit/add-functionality-to-finder-with-action-extensions)

Finder Sync supplies a Finder interface; it does not perform syncing itself. Apple also describes it as intended for synchronisation-related integration rather than arbitrary Finder customisation. Our broader use worked locally, but that is not a guarantee of coverage on every macOS version. [Apple: Finder Sync guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)

## The working menu-to-worker path

```text
Finder selection
  → Finder Sync builds a menu from cached data
  → clicked item identifies a captured request
  → extension writes a small private request file
  → LaunchServices opens that request with the containing app
  → app validates it and runs the shared engine
  → output, job log and optional notification
```

**Keep the extension lightweight.** We use `menu(for:)` only for `.contextualMenuForItems`, return native `NSMenu`/`NSMenuItem` objects and set `autoenablesItems = false`. The callback does no conversion, subprocess work or directory scan. It reads a cached catalogue and the selected URLs. Resolving eligibility once per distinct source type brought the 500-file resolver benchmark down to roughly 3.1 ms median and 3.7 ms p95. This is a resolver measurement, not total Finder response time.

**Capture selection at menu construction.** Store the selected URLs in an immutable request. A later background task must not ask Finder for whichever selection happens to be current then. Apple limits valid selection queries to menu construction and action callbacks. [Apple: contextual-menu selection](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html#//apple_ref/doc/uid/TP40014214-CH15-SW8)

**Use a value Finder actually carries across its boundary.** Our first approach stored a custom object in `NSMenuItem.representedObject`; that did not survive the Finder proxy in our test. An integer `tag` did. We now map each tag to the captured request within that extension instance. Tags are not global job IDs; the submitted request receives a UUID filename.

**Launching an app is not proof that it received its arguments.** `NSWorkspace.openApplication` launched the app, but the command-line arguments were absent. The installed SDK explicitly says: “If the calling process is sandboxed, the value of this property is ignored.” That comment is on `NSWorkspace.OpenConfiguration.arguments`. Do not repeat this debugging detour.

**Document-open delivery worked.** The extension writes a JSON request into its sandbox container, then calls `NSWorkspace.shared.open([requestURL], withApplicationAt: appURL, configuration: ...)`. The configuration creates a new app instance, avoids Recent Items and does not activate the ordinary worker. The app declares a private request document type and receives URLs through `application(_:open:)`.

The request folder uses mode 0700 and request files use 0600. The app validates the canonical folder, UUID filename, extension, current-user ownership, regular-file type and a 1 MB size limit before decoding. It then revalidates the operation and inputs. A received path is not permission to access or move a file.

**Account for launch ordering.** `application(_:open:)` can arrive before `applicationDidFinishLaunching`. We save an early request and dispatch it after launch. Normal explicit app launch shows setup; a request launches a worker. User-facing PDF page selection temporarily opens a normal native window.

**This request mechanism is not a durable queue.** rmconvert removes a request after reading it. It does not provide crash-safe delivery, acknowledgement, replay prevention across a durable journal or recovery of an interrupted move. Those properties need separate treatment for an automatic filer.

## Sandbox, signing and installation lessons

The Finder extension is sandboxed. Its entitlements are `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-only`. The containing app is not sandboxed and performs work subject to normal macOS permissions. There is no App Group, Mach service or XPC service in the working implementation. Do not assume a sandboxed filer or App Store build can use the same access arrangement unchanged.

We successfully compiled, ad hoc signed, registered and ran this on Apple silicon, macOS 27.0 build 26A5425a, with Xcode 26.6 and Swift 6.3.3. No usable paid signing identity was available. This proves a local installation on this Mac; it is not a notarisation or distribution solution. A compiler smoke test succeeded despite an earlier Xcode first-launch status check returning 69, so actual build/run evidence was more useful than a prerequisite checkbox.

Build the real `.app`, with the `.appex` inside `Contents/PlugIns`. Sign contained executables and the extension before signing the containing app; verify the completed bundle. Launch GUI apps through LaunchServices (`open -n`), not by executing the GUI binary directly. Our single entry point is `script/build_and_run.sh`.

**Build staging in iCloud-backed Documents caused signing trouble.** File-provider/Finder metadata on the staged bundle interfered with signing. Staging in `/private/tmp/rmconvert-build-<uid>` and packaging from there resolved it. Keep source in the preferred project folder, but stage the built bundle outside cloud-managed storage. Do not indiscriminately strip extended attributes from the user’s files.

**Registration, enablement and permissions are separate.** `pluginkit` registers/selects the extension; the app checks `FIFinderSyncController.isExtensionEnabled` and can open extension management. Neither registration nor monitoring a folder confers unrestricted read/write permission. Passing tests from a developer terminal does not prove the Finder-launched worker has identical access.

**Use separate product identities for the filer.** rmconvert uses `com.robertsmacros.rmconvert` and `.Finder`. Reusing those IDs, its request document type or its notification names could make the two apps replace one another or consume the wrong requests.

**Duplicate menus were an integration problem, not duplicate menu-building code.** We encountered duplicate entries after repeated installs. `pluginkit` showed one registration while multiple relevant extension processes remained. Disabling/unregistering the stale extension, stopping its stale process, re-registering/enabling and a controlled Finder restart cleared the duplicate entries. macOS can legitimately create extra extension instances for other hosts, so process count alone is not proof of a fault. Avoid casual repeated restarts or broad process killing.

**Updates must not kill active jobs.** Our update path closes setup-only instances and refuses to overwrite an app while workers/page windows remain active. A just-starting setup app can briefly fail that check. An automatic filer needs its own orderly stop/drain/resume behaviour; do not use a blanket process-name kill as a job-management strategy.

## State, file handling and diagnostics worth reusing

The app and CLI share the engine so behaviour can be tested without driving Finder. Keep that separation for the filer. It should not need rmconvert’s image, Office or media dependencies merely to move files.

The app publishes validated catalogue/capability snapshots through distributed notifications. The extension caches them in its own preferences, tied to the bundled catalogue bytes. This is a cache-refresh mechanism, not an authenticated command channel or reliable queue. It may be unnecessary for a simpler filing action.

For generated outputs we stage beside the destination and publish with `renameatx_np(..., RENAME_EXCL)`, retrying numbered names on collision. Sixteen concurrent publications were tested without overwriting. This establishes a useful **no-overwrite principle**, not a complete iCloud move implementation: the converter keeps its source, and its rename is within one filesystem. A filer must account for source removal, cross-volume moves and provider coordination.

Canonical paths exposed another trap: macOS Data-volume aliases can resolve underneath `/System/Volumes/Data`. A blanket “anything starting with `/System` is forbidden” check rejected ordinary user files. We only normalise the Data-volume alias after verifying that both paths identify the same filesystem object. Decide explicitly whether filing a symlink means moving the link or its target; do not inherit the converter’s symlink resolution accidentally.

We rejected cloud placeholders that were not downloaded; we did not implement their download lifecycle. We also treated RTFD as a package rather than an ordinary directory. A general filer needs an explicit policy for folders, packages, aliases, locked files, metadata, tags and extended attributes.

Logs record individual successes and failures with paths. A failed batch member does not conceal successful members. Our per-job logs are capped at 30 days/1,000 records, with a readable app view. A move journal used for recovery or undo is a different data store and should not simply inherit this diagnostic-log retention policy.

## The icon lesson and builds 3–5

The full Roberts Macros bitmap looks correct in the setup window. We tried cropping it, deriving an alpha mask and using it as an `NSImage` template for both Finder menu headings.

**A user subsequently reported a black box in Finder. Build 3 removes that rendering approach.** Earlier automated checks and menu accessibility inspection proved menu presence and behaviour, not that the icon’s pixels looked correct. Finder screenshots were unavailable through our UI tool; the report must take precedence over any earlier implication that branding was finished.

We prepared alternatives using actual Apple system symbols: opposing arrows for Convert and stacked pages for PDF, a circular-arrow/document pair, or a restrained RM monogram. Build 3 now uses the opposing-arrow and stacked-page system symbols directly, replacing the custom bitmap template. Both symbols survived secure image archiving with transparent backgrounds. The corrected build was installed and the Finder extension refreshed. The user confirmed that the symbols appeared, but their black tint was too strong. Build 4 applies an adaptive `secondaryLabelColor` palette with `isTemplate = false`; keeping template mode enabled would allow Finder to override that palette. Securely archived images rendered with transparent backgrounds and different light/dark colours. Actual Finder menu screenshots remain unavailable through the UI tool, so these checks do not prove exact matching or highlighted-state appearance. The user’s next screenshot showed build 4 remained too dim. Rendering checks found that its translucent palette effectively multiplied opacity twice. Build 5 draws transparent 1×/2× images and applies `labelColor` once with source-in compositing; the extension refreshes cached images when its effective appearance changes. After image archiving, maximum glyph opacity is approximately 0.85 in both appearances. For the filer, a simple monochrome system symbol is the practical starting point, with the full brand in setup. Inspect the actual Finder menu in light, dark and selected states. A mockup is not that test. [Apple: SF Symbols](https://developer.apple.com/sf-symbols/)

## What changes for an automatic iCloud filer

These are implications for a future implementer to investigate, **not features implemented or tested in rmconvert**:

- **A right-click command and automatic filing have different lifecycles.** Finder’s browsing callbacks are not a reliable background folder watcher. If filing must continue when Finder and setup are closed, choose a separate supported background component and durable work queue. Finder Sync can remain the manual interface. Apple makes the same separation between Finder UI and the component that performs synchronisation. [Finder Sync performance guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
- **Choose and retain authorised folders.** Verify the actual source and iCloud destination on this Mac. Do not manufacture a path from a display name, confuse an app-specific ubiquity container with the user’s iCloud Drive, or assume the extension’s selection access transfers to a helper. Persistent access depends on the chosen sandbox/helper model and must survive relaunch.
- **Local placement is not completed cloud upload.** The SDK exposes separate download, upload and upload-error resource keys. An item existing at the destination is not sufficient evidence that this version has finished syncing. Handle unavailable/unknown states, offline operation, conflicts and quota errors explicitly. Decide whether the product promises filing into the local iCloud folder or confirmed remote availability. [Apple: ubiquitous item upload state](https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemisuploadedkey)
- **Coordinate changes with the document/provider system.** Investigate `NSFileCoordinator` and its move notifications for the selected access model. Coordination does not itself grant permission or guarantee upload completion. Do not copy rmconvert’s raw rename as a universal provider-safe move. [Apple: NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- **Make interruption and retries safe.** Never overwrite an unrelated destination. Handle a source changing during processing, an existing identical file, cross-volume copy failure and a crash between destination publication and source removal. Give repeat events a defined, idempotent result. If observing folders, exclude the destination and own temporary files, avoid filing incomplete downloads, and reconcile after sleep or missed events.

## Evidence to inherit, and evidence still needed

rmconvert passed 172 generated-file checks, including a 200-document batch. Real Finder actions converted a filename containing spaces, an apostrophe, an ampersand, accents and an emoji; extracted PDF pages through the native UI; and launched a PDF worker with setup closed. Original conversion inputs were preserved.

Those results prove the tested local conversion and menu-to-worker path. They do **not** prove moving files into iCloud, preserving metadata during moves, safe source deletion, automatic watching, recovery, undo or remote upload completion.

Reboot persistence, notification delivery/click behaviour and full coverage of protected, cloud-provider, search and external-volume Finder locations remain unverified. Before relying on the filer, exercise its actual installed worker with disposable files in its actual source and destination folders, including collisions, missing permissions, offline/cloud placeholders, interruption and retry. The first useful integration milestone is one real filing operation from the chosen Finder surface with the main app closed.

## Source pointers

Reference application: `/Applications/rmconvert.app`. These files are references to inspect and adapt, not a requirement to reuse the converter’s full architecture.

| Reference | Contents |
|---|---|
| [FinderSync.swift](../Sources/Extension/FinderSync.swift) | Menu callback, captured requests, tags and document-open dispatch |
| [App.swift](../Sources/App/App.swift) | Request validation, launch ordering, worker/setup separation and log UI |
| [Catalog.swift](../Sources/Shared/Catalog.swift) | Shared routing and capability model |
| [Engine.swift](../Sources/Shared/Engine.swift) | Canonical paths, staged publication, results and logging |
| [Build script](../script/build_and_run.sh) / [installer](../script/install.sh) | Bundle layout, local staging, signing and registration |
| [Icon proposals](icon-proposals.png) | Design comparison; option A is implemented in build 3 |
| [Repository overview](../README.md) | Converter code, scripts and tests; read this handover’s icon correction alongside its earlier validation notes |

The implementation-specific observations above come from local code, SDK headers and actual runs. The iCloud section records follow-on considerations and relevant Apple APIs, not an assertion that the filer has been built.
