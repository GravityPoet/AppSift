# AppSift high-risk and real-system QA

This document is the release gate for cleanup, maintenance, scanner scale, compatibility, localization, and accessibility changes. Automated fixtures never use a live browser profile, real device backup, or the user's Trash.

## Automated gates

Generate the project before running either scheme:

```bash
xcodegen generate
```

Run all unit, fixture, cancellation, and scale tests:

```bash
xcodebuild \
  -project AppSift.xcodeproj \
  -scheme AppSift \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath /tmp/AppSift-QA-Derived \
  ARCHS="$(uname -m)" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Run the macOS accessibility UI audits on macOS 14 or newer. The test runner must be signed and allowed to perform UI automation:

```bash
xcodebuild \
  -project AppSift.xcodeproj \
  -scheme AppSiftAccessibility \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath /tmp/AppSift-Accessibility-QA \
  ARCHS="$(uname -m)" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  test
```

The automated suite covers:

- disposable Safari, Chrome, and Firefox profiles;
- Firefox SQLite history and download cleanup, private rollback backup, exact restore, sidecars, bookmark preservation, manifest failure, and stale-undo refusal;
- moving reviewed files to an isolated Trash, undo, changed-file refusal, rollback after history-write failure, and partial failure reporting;
- simulated iPhone/iPad backups, download-source files, and similar-image suggestions through delete and undo flows;
- PhotoKit read/write authorization, denied and revoked access, local-only thumbnail requests, iCloud-only skips, Live Photo/RAW/burst asset modeling, 20,000-asset truncation, pre-delete revalidation, transaction failure, post-delete verification, and routing to Recently Deleted instead of Finder Trash;
- real directory fixtures for old-user residue and malformed property lists;
- DNS authorization cancellation, exact command construction, Spotlight disconnection and authorization failure, and Mail permission or quit refusal;
- denied notification delivery while alert state and history remain correct;
- Space Lens and duplicate-file active cancellation, disconnected roots, large directories, and hard-link physical-allocation accounting;
- the 20,000-image and 2,000,000-comparison production limits for similar-image scanning;
- all seven localization catalogs, feature-view string extraction, and a guard against untranslated new narrative copy;
- accessibility labels, hierarchy, actions, and light/dark contrast through the `AppSiftAccessibility` UI-test scheme.

## Compatibility gate

GitHub Actions runs the unit suite on these real hosted environments:

| Runtime | Architecture | Gate |
| --- | --- | --- |
| macOS 14 | Apple Silicon | Unit, fixture, cancellation, and scale suite |
| macOS 15 | Apple Silicon | Unit suite plus universal Release build |
| macOS 15 | Intel | Native x86_64 unit suite |

The deployment target remains macOS 13, but compilation for a 13.0 target is not a substitute for running on Ventura. GitHub no longer provides a macOS 13 hosted runner, so every release still requires one physical or virtual macOS 13 run using the unit-test command above and the manual checks below.

Record the exact `sw_vers`, `uname -m`, `xcodebuild -version`, commit, and result-bundle path for each compatibility run. The accessibility UI-test target intentionally starts at macOS 14; macOS 13 compatibility is validated by the app and unit-test targets plus the manual checks below.

## Disposable real-system profiles

Never point a QA cleanup at an active profile. Quit the browser, copy the minimum profile into a newly created test account or disposable folder, and make a second untouched copy before scanning.

For each of Safari, Chrome, and Firefox:

1. Add a known history entry, download record, cookie, cache file, bookmark, saved login, and autofill value to the disposable profile.
2. Scan and verify that history, downloads, cookies, and caches are listed independently.
3. Verify that bookmarks, saved logins, autofill, tabs, extensions, and Wi-Fi data are absent from the cleanup selection.
4. Clean one SQLite-backed category while the browser is closed; reopen the browser and confirm the selected records are gone and bookmarks remain.
5. Undo the cleanup and compare the database and relevant sidecars with the untouched copy.
6. Repeat with the browser open, a read-only database, an interrupted manifest write, and insufficient directory permission. No partially modified profile may remain.

## Device backups, downloads, and image fixtures

- Create at least two synthetic Finder backup directories for the same device and one for another device. Include valid `Info.plist`, `Manifest.plist`, encryption metadata, dates, and payload files. Verify grouping, newest-backup protection, physical size, selected deletion, undo, malformed metadata, and a directory that disappears during scanning.
- Create ordinary Safari, Chrome, Slack, and unknown-source downloads with bounded quarantine metadata. Verify source grouping, domain-only display, no full URL disclosure, selected deletion, partial failure, and undo.
- For regular folders, test JPEG, HEIC, PNG, rotated, cropped, compressed, cloud-placeholder, and unreadable files. A managed `.photoslibrary` package must remain blocked at the root, traversal, and deletion layers; regular-folder deletion must go to the macOS Trash and its undo history must restore exact files.

### Disposable Photos Library QA

PhotoKit always addresses the current user's system photo library; it does not provide a public API for selecting an arbitrary library path. Use a dedicated macOS QA account or an otherwise disposable system photo library. Never select an existing personal asset for deletion.

1. Import uniquely named QA assets: two similar JPEG/HEIC images, one RAW+JPEG pair, one Live Photo, and at least two members of one burst. Record their local identifiers or filenames before testing.
2. Start the scan from the Photos Library source. Verify the read/write permission prompt appears only after this explicit action and uses the localized purpose string. Test authorized, denied, and permission-revoked states.
3. Verify the scan shows only PhotoKit-accessible image assets, keeps Live Photo/RAW/burst badges attached to one asset, and does not expose package-internal paths. With network access disabled, an iCloud-only asset must be counted as skipped rather than downloaded.
4. Select only uniquely named QA assets. Confirm the dialog says Recently Deleted, never Finder Trash, and preserves at least one asset in every group.
5. Edit one selected QA asset in Photos after scanning and then confirm cleanup. AppSift must reject the whole request and require a rescan.
6. Rescan, delete one QA asset, and verify Photos places the complete asset in Recently Deleted. The Live Photo motion resource and RAW/JPEG resources must not be split. Recover the asset from Recently Deleted and verify it opens correctly.
7. Revoke Photos permission during a second run and verify no deletion occurs. Save screenshots of the permission state, confirmation, Recently Deleted result, and restored asset as release evidence.

## External storage and failure injection

Use a disposable external APFS volume containing normal files, hard links, an APFS clone, an unreadable directory, and enough generated data to approach the low-space threshold.

1. Scan the root with Space Lens and duplicate scanning; verify hard links and confirmed clones are not double-counted.
2. Disconnect the volume during enumeration, hashing, aggregation, preview, and reviewed deletion. The operation must stop with an error and must not present a partial result as complete.
3. Cancel each scanner during enumeration and hashing. The UI must return to an idle state promptly and retain no actionable partial selection.
4. Fill the disposable volume until the configured external-disk warning fires. Verify the alert names the correct volume and does not confuse logical size with reclaimable physical size.
5. Deny notification authorization and repeat the warning. The in-app condition and history must remain visible even though no notification is delivered.

## Scale and resource gate

Run the scale tests on both Apple Silicon and Intel. In addition, perform these release-candidate runs with Activity Monitor or Instruments attached:

| Workload | Pass criteria |
| --- | --- |
| 20,000 supported images | Discovery stops at 20,000; no 20,001st image is decoded |
| Dense similar-image set | Pair generation stops at 2,000,000 comparisons and reports truncation |
| Two million-file directory tree | Cancellation remains responsive; memory growth is bounded and returns after releasing the result |
| Large duplicate scan | Files are narrowed by size and sampled hash before full hash; cancellation interrupts both enumeration and hashing |
| 100+ hard-link sets | Physical allocation is counted once per inode and every alias remains protected from cleanup |
| External volume removal | Scanner fails closed without retaining a result marked complete |

Capture wall time, peak resident memory, file count, comparison count, cancellation latency, skipped placeholder count, hard-link alias count, and APFS-clone alias count. Treat an unexplained regression above 20% from the previous release candidate as a failure requiring investigation rather than silently moving the baseline.

## Accessibility and localization gate

Run every new page in all seven supported languages at the minimum 980 × 600 window and at the largest practical display/text scaling setting.

- VoiceOver: traverse forward and backward, activate every control, inspect grouped rows and the Space Lens map, confirm icon-only controls have concise labels, and verify dialogs move focus logically.
- Full Keyboard Access: reach the sidebar, filters, tables, selection controls, menus, destructive confirmations, Cancel, Undo, and close buttons without a pointer. The sidebar uses native buttons rather than tap-only gestures.
- Increase Contrast and Differentiate Without Color: test light and dark appearances. Selection, warning, success, protection, and disabled states must remain understandable from text or symbols rather than color alone.
- Scaling: verify no heading, explanation, path, badge, button, table row, or confirmation text is clipped; scrollable content must remain reachable at the minimum window size.
- Localization: verify no English narrative copy appears in Arabic, Spanish, Japanese, Brazilian Portuguese, Simplified Chinese, or Traditional Chinese; interpolation and plural values must remain in the correct order.

Automated accessibility audits are screen-specific and do not replace a complete VoiceOver pass. Save the Accessibility Inspector report or XCTest result bundle with the release evidence.

## Release evidence

For every manual run, record:

- commit and build configuration;
- macOS, architecture, Xcode, filesystem, and whether the volume is internal or external;
- fixture description and pre-test backup location;
- expected and observed result;
- recovery/undo result;
- peak memory and elapsed time for scale runs;
- screenshots or result-bundle paths for failures;
- tester and date.

A path that modifies real user data, produces an unrecoverable partial cleanup, loses an undo record, bypasses a production limit, or cannot be completed with VoiceOver and keyboard is a release blocker.
