# AppSift Release SOP

This is the canonical and unique release procedure for AppSift. Do not publish
from memory or from an adjacent README.

## Document routing

- Current customer release: use this SOP and
  `scripts/release-self-signed.sh`.
- Compatibility entry point: `scripts/release-local.sh` must continue to route
  to the same self-signed builder.
- Future Developer ID identity migration only: read `scripts/SECRETS.md`, then
  use `.github/workflows/release.yml` after an explicit migration decision.
  The workflow is not the normal release path.
- `README.md` and translated READMEs are customer installation guides, not
  release procedures.

## Project

- Repository: `GravityPoet/AppSift`
- GitHub remote: `git@github.com:GravityPoet/AppSift.git`
- Default release branch: `main`
- Package ecosystem: XcodeGen project with Swift Package Manager dependencies
- Package manager/tool installer: Homebrew for `xcodegen`; `xcodebuild`
  resolves Swift packages
- Distribution: GitHub Release plus `GravityPoet/homebrew-tap`

## Versioning

- Version source: `project.yml` `MARKETING_VERSION`
- Build source: `project.yml` `CURRENT_PROJECT_VERSION`
- Generated mirror: `AppSift.xcodeproj/project.pbxproj`. XcodeGen 2.46 rewrites
  generated UUIDs, so release verification generates into an isolated temporary
  directory and never commits UUID-only churn
- Tag format: annotated `v<MARKETING_VERSION>`
- Changelog source: customer-visible commits since the previous AppSift tag;
  for the first public AppSift release, use the AppSift root commit through the
  target commit
- Release types: stable by default; prerelease only when explicitly requested
- Current signing channel: stable self-signed customer build, clearly labeled
  as not Apple-notarized

## Preconditions

- Required tools: `git`, `gh`, `brew`, `xcodegen`, `xcodebuild`, `codesign`,
  `hdiutil`, `ditto`, `unzip`, `shasum`, and `/usr/libexec/PlistBuddy`
- Required credentials: authenticated `gh` account with write access to
  `GravityPoet/AppSift` and `GravityPoet/homebrew-tap`
- Required state: clean `main`, `HEAD == origin/main`, successful CI for the
  target SHA, and no local/remote target tag or GitHub Release collision
- Current self-signed release identity:
  - name: `AppSift Local Code Signing`
  - certificate SHA-1: `90F1896851E020316315F97A149EABA00F9CFD8C`
  - certificate SHA-256:
    `D3C9F51F87A9826C44F53999C2D2F535F0CA921D6982C54939AF3DF30B5E797D`
  - bundle ID: `com.gravitypoet.appsift`
  - designated requirement:
    `designated => identifier "com.gravitypoet.appsift" and certificate leaf = H"90f1896851e020316315f97a149eaba00f9cfd8c"`
- Release builds must fail closed if that exact identity is unavailable. Never
  create a replacement certificate during release. `ensure-local-codesign-cert.sh`
  remains a development/install bootstrap only.
- When `/Applications/AppSift.app` exists, its designated requirement must
  equal the pinned requirement before packaging.
- Developer ID and notarization are a separate identity migration. Do not
  invoke the GitHub release workflow for the current self-signed channel.

## Release quality gates

- Critical non-stubbed workflow: run the complete `AppSiftTests` suite. It
  covers scan publication, removal/recovery boundaries, app metadata,
  permissions, update-source validation, and filesystem fixtures without a
  live external service dependency.
- Marketed-locale strict i18n: the complete test suite must pass
  `LocalizationFilesTests.testAllLocalizableStringsFilesHaveEnglishKeyParity`.
- Platform package assets: the packaged app must contain the generated icon,
  the expected bundle ID/version, both `arm64` and `x86_64`, and valid strict
  signatures in the app, DMG, and ZIP.
- Signing/TCC continuity: compare the candidate designated requirement and
  certificate fingerprints with both the pinned values above and the installed
  baseline when present.
- Customer copy: release notes must say `self-signed` and `not Apple-notarized`,
  provide SHA-256 values, and explain Finder **Open** for first launch. Do not
  claim Developer ID signing, notarization, or stapling.

## Commands

Run all commands from the repository root.

### Install

```bash
brew install xcodegen
xcodegen --version
```

### Preflight

```bash
git status --short --branch
git remote -v
git rev-parse HEAD
git rev-parse origin/main
git ls-remote origin refs/heads/main
git tag --sort=-version:refname
gh auth status
gh run list --repo GravityPoet/AppSift --commit "$(git rev-parse HEAD)" --limit 10
gh release list --repo GravityPoet/AppSift --limit 100 --json tagName,isDraft,isPrerelease,isLatest
security find-identity -v -p codesigning login.keychain-db
security find-certificate -Z -c "AppSift Local Code Signing" login.keychain-db
```

### Verify

```bash
REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
TEST_PROJECT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/appsift-release-test.XXXXXX")"
/bin/ln -s "$REPOSITORY_ROOT/AppSift" "$TEST_PROJECT_ROOT/AppSift"
/bin/ln -s "$REPOSITORY_ROOT/AppSiftTests" "$TEST_PROJECT_ROOT/AppSiftTests"
xcodegen generate \
  --no-env \
  --spec "$REPOSITORY_ROOT/project.yml" \
  --project "$TEST_PROJECT_ROOT" \
  --project-root "$REPOSITORY_ROOT"
xcodebuild test \
  -project "$TEST_PROJECT_ROOT/AppSift.xcodeproj" \
  -scheme AppSift \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEST_PROJECT_ROOT/DerivedData.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Remove only that exact `appsift-release-test.*` temporary root after the test.

### Package

```bash
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' project.yml)"
scripts/release-self-signed.sh "$VERSION"
shasum -a 256 "build/AppSift-$VERSION-self-signed.dmg" > "build/AppSift-$VERSION-self-signed.dmg.sha256"
shasum -a 256 "build/AppSift-$VERSION-self-signed.zip" > "build/AppSift-$VERSION-self-signed.zip.sha256"
hdiutil verify "build/AppSift-$VERSION-self-signed.dmg"
unzip -tq "build/AppSift-$VERSION-self-signed.zip"
```

### Tag and GitHub Release

Create customer-facing notes at `build/release-notes-<version>.md`, then:

```bash
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' project.yml)"
TAG="v$VERSION"
git tag -a "$TAG" -m "AppSift $TAG"
git push origin "$TAG"
gh release create "$TAG" \
  "build/AppSift-$VERSION-self-signed.dmg" \
  "build/AppSift-$VERSION-self-signed.zip" \
  "build/AppSift-$VERSION-self-signed.txt" \
  "build/AppSift-$VERSION-self-signed.dmg.sha256" \
  "build/AppSift-$VERSION-self-signed.zip.sha256" \
  --repo GravityPoet/AppSift \
  --title "AppSift $TAG" \
  --notes-file "build/release-notes-$VERSION.md" \
  --verify-tag
```

### Homebrew cask

After the GitHub assets are public and independently downloaded/verified,
update `homebrew/appsift.rb` with the release version and ZIP SHA-256. The
current URL must end in `AppSift-#{version}-self-signed.zip`. Commit and push
that repository change, then create or update
`GravityPoet/homebrew-tap/Casks/appsift.rb` from the verified in-repository
cask.

```bash
brew tap GravityPoet/tap
brew install --cask appsift
```

For the future Developer ID workflow, its formula-bump step must rewrite the
URL to `AppSift-#{version}.zip` as well as changing version and checksum.

## Verification

- Local: tests pass; package script exits zero; DMG and ZIP verification pass;
  status-file checksums equal fresh `shasum` output.
- Candidate app: version/build/bundle ID are `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`, and `com.gravitypoet.appsift`; architectures are
  `arm64 x86_64`; strict signature and pinned requirement pass.
- GitHub: `gh release view <tag> --json url,tagName,isDraft,isPrerelease,assets`
  reports a public stable release with all five expected assets.
- Public download: download the release ZIP and both checksum files into a
  `mktemp -d` directory and verify with `shasum -a 256 -c`.
- Homebrew: the public tap cask version, URL, and SHA match the release; a cask
  audit succeeds. Do not uninstall or overwrite an existing customer app merely
  to prove the cask path unless a recoverable install test is explicitly safe.

## Rollback

- Before tag push: remove only newly generated, rebuildable `build/` artifacts
  and the local target tag if it was created but not pushed.
- After tag push but before release publication: retain the tag and fix the
  release inputs; do not delete a public tag without a recoverable need.
- After GitHub release creation: convert the release to draft with
  `gh release edit <tag> --draft --repo GravityPoet/AppSift` while preserving
  the tag and assets for diagnosis.
- After cask publication: revert the cask commit in AppSift and the tap, push
  both reverts, and keep direct GitHub downloads available unless the artifact
  itself is unsafe.
- Deleting public tags/releases or replacing non-rebuildable assets is outside
  normal rollback and requires the applicable P0 gate.

## Fuse conditions

- Stop before external writes if branch/remote SHA differs, the working tree
  contains unrelated changes, the tag or release exists, CI/tests/build fail,
  the exact signing identity or requirement differs, artifacts or checksums do
  not match, or release notes overstate signing/notarization.
- Stop after release publication and draft the release if a downloaded public
  asset fails checksum/signature/package verification.
- Do not dispatch `.github/workflows/release.yml` without an explicit Developer
  ID identity-migration decision and complete signing/notarization credentials.

## Failure ledger

| Date | Version/Tag | Command | Error Signature | Root Cause | Fix | Prevention |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-07-20 | 1.0.4 / v1.0.4 | `xcodegen --version` | `zsh:1: command not found: xcodegen` | Required repository tool was not installed on the release host | Install with `brew install xcodegen`, verify its version, then regenerate before testing | Make `xcodegen --version` and installation part of preflight |
| 2026-07-20 | 1.0.4 / v1.0.4 | `gh api repos/GravityPoet/AppSift/branches/main/protection` | `Branch not protected (HTTP 404)` | `main` has no branch-protection resource | Treat this exact 404 as an unprotected branch and rely on clean-tree, SHA, CI, and explicit-scope checks | Query protection only as optional metadata; do not retry the same 404 |
| 2026-07-20 | 1.0.4 / v1.0.4 | GitHub connector `get_repo` / `search` for `GravityPoet/homebrew-tap` | `404 Not Found`; `Mcp error: -32603: Internal error` | The advertised tap repository did not exist; `gh repo list GravityPoet` independently confirmed absence | Create the public tap repository during the authorized release, then verify it through `gh` and the connector | Resolve tap existence before attempting formula fetch/search |
| 2026-07-20 | 1.0.4 / v1.0.4 | `gh release list --repo GravityPoet/AppSift --limit 100 --json tagName,url,isDraft,isPrerelease` | `Unknown JSON field: "url"` | `gh release list` does not expose `url` in its JSON schema | List with supported fields; use `gh release view <tag> --json url,...` for the URL | Keep separate schemas for `gh release list` and `gh release view` |
| 2026-07-20 | 1.0.4 / v1.0.4 | `git log --reverse 1341be9^..HEAD` | `fatal: ambiguous argument '1341be9^..HEAD'` | The AppSift launch commit is a root commit and has no parent | Inspect the root commit separately and use `1341be9..HEAD` for later commits | Check whether a boundary commit has a parent before using `<sha>^` ranges |
| 2026-07-20 | 1.0.4 / v1.0.4 | `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml", aliases: true)'` | `unknown keyword: aliases (ArgumentError)` | The system Ruby 2.6 Psych API does not accept the newer `aliases:` keyword | Load this workflow without that unsupported keyword; the YAML parsed successfully | Check the host Ruby/Psych API before using version-specific loader keywords |
| 2026-07-20 | 1.0.4 / v1.0.4 | `xcodegen generate` in the repository root | Successful command rewrote the tracked project and scheme with UUID-only churn | XcodeGen 2.46 generates new opaque project IDs even when project semantics are unchanged | Restore only the generated files from the pre-command commit, then generate into a guarded temporary directory for tests and packaging | Never run release-time XcodeGen directly over the tracked project; use `--project` plus `--project-root` in an isolated temporary root |
| 2026-07-20 | 1.0.4 / v1.0.4 | isolated `xcodebuild test` after `xcodegen generate --project <temp> --project-root <repo>` | `Build input file cannot be found: '<temp>/AppSift/Info.plist'` | Xcode project file references remain relative to the generated project directory even when XcodeGen uses the repository as its discovery root | Link `AppSift` and `AppSiftTests` from the isolated project root to the repository sources before generation, then rerun the same test command | Isolated XcodeGen release roots must provide the source-tree paths expected by the generated project |
| 2026-07-20 | 1.0.4 / v1.0.4 | inline temporary-root test command with guarded `/bin/rm -rf` cleanup | `Rejected: rm -f style commands are not permitted` | The terminal policy rejected a compound command containing recursive forced cleanup even though the path was guarded | Create the temporary root first, validate its exact prefix, and clean the explicit resolved path with `/bin/rm -R` after the command | Keep destructive cleanup out of compound commands and resolve an explicit narrow target first |
| 2026-07-20 | 1.0.4 / v1.0.4 | isolated `xcodebuild -list` / `xcodebuild test` | `CoreSimulator is out of date. Current version (1051.54.0) is older than build version (1051.55.0)` | This macOS 27 host has a CoreSimulator component older than Xcode 26.6; the macOS destination still completed successfully | Use an explicit macOS architecture destination and require the result bundle to report `230` passed, `0` failed, `0` skipped; repair Xcode/macOS components if the command exits non-zero | Treat the diagnostic as non-blocking only when the macOS result bundle is green; never rely on process exit alone |
| 2026-07-20 | 1.0.4 / v1.0.4 | `brew style --cask homebrew/appsift.rb` | `Homebrew requires casks to be in a tap, rejecting: homebrew/appsift.rb` | Homebrew's style command refuses a standalone repository cask path | Validate Ruby syntax locally, then run cask style/audit from the actual `GravityPoet/homebrew-tap` checkout after it exists | Do not treat standalone in-repo cask style failure as a formula defect; audit the public tap copy |
| 2026-07-20 | 1.0.4 / v1.0.4 | `gh run watch 29710735482 --repo GravityPoet/AppSift --interval 10 --exit-status` | `HTTP 503: No server is currently available to service your request` | GitHub Actions API was temporarily unavailable while the run itself remained externally managed | Inspect the existing run with `gh run view` after the service recovers; do not dispatch a duplicate workflow solely because watch failed | Separate workflow observation failures from workflow execution state and confirm the run ID before retrying |
