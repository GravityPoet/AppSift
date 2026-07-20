<p align="center">
  <img src="screenshot_v2.png" alt="AppSift dashboard — animated storage health ring and live composition donut" width="820">
</p>

<p align="center">
  <img src="screenshots/breakdown.png" alt="AppSift scan results — by-category breakdown chart" width="820">
</p>

<p align="center">
  <b>English</b> |
  <a href="docs/README.ar.md">العربية</a> |
  <a href="docs/README.es.md">Español</a> |
  <a href="docs/README.ja.md">日本語</a> |
  <a href="docs/README.zh-Hans.md">简体中文</a> |
  <a href="docs/README.zh-Hant.md">繁體中文</a>
</p>

<p align="center">
  <img src="docs/assets/icon.png" alt="AppSift eraser app icon" width="128">
</p>

<h1 align="center">AppSift</h1>

<p align="center">
  <b>Reclaim your soldered SSD. A telemetry-free macOS cleaner & uninstaller that saves your storage—and your wallet.</b><br>
  <i>夺回被焊死的 Mac 空间。一款零隐私泄露的 Mac 清理与卸载神器，专治存储焦虑。</i>
</p>

<p align="center">
  <a href="https://github.com/GravityPoet/AppSift/releases/latest"><img src="https://img.shields.io/github/v/release/GravityPoet/AppSift?style=flat-square&label=Download" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Universal-arm64%20%2B%20x86__64-blue?style=flat-square" alt="Universal arm64 and x86_64 build">
  <img src="https://img.shields.io/badge/telemetry-none-success?style=flat-square" alt="No telemetry">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/GravityPoet/AppSift?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/GravityPoet/AppSift/stargazers"><img src="https://img.shields.io/github/stars/GravityPoet/AppSift?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/GravityPoet/AppSift/releases"><img src="https://img.shields.io/github/downloads/GravityPoet/AppSift/total?style=flat-square&label=Downloads" alt="Downloads"></a>
</p>

<p align="center">
  <a href="#-quick-start--快速开始">Quick Start</a> -
  <a href="#-the-why--为什么我们需要这个项目">The Why</a> -
  <a href="#-before-vs-after--痛点对比">Before vs. After</a> -
  <a href="#-key-features--杀手级特性">Features</a> -
  <a href="#-who-needs-this--典型场景">Who Needs This</a> -
  <a href="#-how-it-compares--同类对比">How it Compares</a> -
  <a href="#-our-promise--我们的承诺">Our Promise</a> -
  <a href="#-detailed-feature-breakdown--功能深度详解">Detailed Features</a> -
  <a href="#-permissions--权限说明">Permissions</a>
</p>

---

## ⚡ Quick Start / 快速开始

Start clearing space in less than 60 seconds:
*在 60 秒内上手释放空间：*

```bash
# 1. Tap the repository / 添加仓库源
brew tap GravityPoet/tap

# 2. Install AppSift / 安装 AppSift
brew install --cask appsift
```

Or download the latest `.dmg` from [Releases](https://github.com/GravityPoet/AppSift/releases/latest) and drag AppSift into `/Applications`.
*或者直接从 [Releases](https://github.com/GravityPoet/AppSift/releases/latest) 下载最新的 `.dmg` 并拖入应用程序文件夹。*

For developers who want to inspect and compile locally, check out the [Advanced Source Build Guide](#-advanced-source-build-guide--进阶源码编译指南).
*如果你是希望本地审查并自主编译的开发者，请参考 [源码编译指南](#-advanced-source-build-guide--进阶源码编译指南)。*

---

## 🎯 The Why / 为什么我们需要这个项目？

### English
Why does the world need another Mac cleaner? Because Apple sells base-model Macs with **soldered, non-upgradable SSDs** at astronomical prices, while commercial cleaning utilities charge predatory annual subscriptions, leak your app usage metadata, and trade on fake urgency and FUD (Fear, Uncertainty, and Doubt) like *"47 GB of critical junk detected!"* to scare you into buying.

AppSift is the antidote. It is **100% free**, **MIT-licensed**, completely **offline-first**, and brutally honest about what can actually be purged. It recovers gigabytes of lost space by targeting actual system and developer clutter, without gimmicks.

### 简体中文
为什么这个世界还需要一款 Mac 清理工具？因为苹果高昂的固态硬盘升级费让很多人只能选择 256GB 的低配 Mac，而市面上的商业清理软件大多采用昂贵的订阅制，默认收集并上传你的隐私数据，还喜欢用*“发现 47 GB 危险垃圾”*这种虚假警报来恐吓你续费。

AppSift 就是为此而生的终结者。它 **100% 免费**、**基于 MIT 协议开源**、完全**本地运行且绝无联网收集隐私**。它不搞虚头巴脑的噱头，只用最干净、最诚实的方式，帮你把被开发缓存和残留垃圾蚕食的硬盘空间一寸一寸夺回来。

---

## ⚖️ Before vs. After / 痛点对比

| Before AppSift (The Pain) ❌ | After AppSift (The Joy) 🎉 |
|---|---|
| Paying $40+/year for disk utilities just to click "Clean". | **100% Free (MIT)**. Keep your hard-earned budget. |
| Creepy trackers & telemetry profiling your app usage history. | **Zero Telemetry**. Bounded, offline-first. It doesn't even know you exist. |
| Leftovers from deleted apps (plists, containers, launchdaemons) silently rotting in `~/Library`. | **Deep Orphan Scan**. Matches bundles to trace and sweep every hidden byte. |
| Dev caches (Xcode, Node, Docker, Ollama) eating 50GB without you knowing. | **Developer-First Purger**. Safely wipes giant compiler, package, and LLM caches in one click. |
| Dramatized red counters crying "Your Mac is in danger!" | **Honest Statistics**. Real paths, transparent rules, absolute control. |

| 没有 AppSift (痛苦现状) ❌ | 拥有 AppSift (爽快体验) 🎉 |
|---|---|
| 每年花 200+ 元订阅清理软件，只为了点一下“一键清理”。 | **100% 免费 (MIT)**，把预算留给真正重要的地方。 |
| 清理软件在后台默默监控你的应用使用习惯和数据，隐患重重。 | **零遥测，零跟踪**。完全离线运行，应用甚至不需要知道你是谁。 |
| 拖拽到垃圾桶的软件在 `~/Library` 下残留大量冷冻的废弃文件。 | **深度残留扫描 (Orphan Finder)**，深度匹配 bundle 连根拔起。 |
| 各种开发缓存 (Xcode, Docker, Ollama) 动辄吃掉几十 G 空间。 | **开发者专属清理**。一键安全清理大型编译器、容器与本地模型缓存。 |
| 各种红色惊叹号和虚假警告弹窗恐吓你“系统处于危险中”。 | **诚实扫描**。只展示真实路径，绝不使用恐吓营销。 |

---

## 🚀 Key Features / 杀手级特性

- **⚡ Smart Uninstaller & Deep Orphan Finder / 智能卸载与残留清理**
  * **EN**: Dragging apps to the Trash leaves up to 70% of their data behind. AppSift maps application bundle identifiers and containers to trace every plist, launch agent, and log, deleting them safely via Finder-semantic recycle or letting you restore them instantly.
  * **ZH**: 普通的“拖入垃圾桶”会残留 70% 的废弃数据。AppSift 深入系统底层，匹配 bundle ID，自动识别并清理所有关联 plist、启动项和日志，而且删除默认进回收站，支持一键安全还原。

- **⚙️ Developer-First Cache Purger / 开发者特供清理**
  * **EN**: Modern development stacks are storage vampires. AppSift scans and safely flushes giant cache folders from Xcode (`DerivedData`, simulators), Node (`npm`, `yarn`, `pnpm`), Docker (dangling images/containers), and local AI tools like Ollama and LM Studio.
  * **ZH**: 现代开发工具是名副其实的空间杀手。AppSift 专为工程师设计，可安全一键清理 Xcode、Node (npm/yarn/pnpm)、Docker (无用镜像与容器) 以及本地 AI (Ollama/LM Studio) 的庞大缓存。

- **🛡️ Bounded, Offline-First & Finder-Safe / 安全透明，绝对掌控**
  * **EN**: Zero analytics, zero network tracking. Destructive actions use macOS Finder-semantic recycle (`NSWorkspace.recycle`) to move files to Trash instead of permanent deletion, preventing accidental data loss. Safe paths are hardcoded to protect your system.
  * **ZH**: 没有任何后台上传或联网分析。所有删除操作默认移动到系统垃圾桶，随时可以后悔。核心系统路径被硬编码锁定保护，绝不会误伤系统。

---

## 👥 Who Needs This / 典型场景

- 💻 **Mac Mini / Base Macbook Owners:** Married to a 256GB SSD and fighting for every megabyte.
  * *低配 Mac 钉子户：坚守 256GB 固态硬盘，每天都在为几百兆空间腾挪。*
- 🛠️ **Developers & AI Engineers:** Drowning in Xcode DerivedData, npm dependencies, Docker layers, and heavy LLM model caches.
  * *开发者与 AI 工程师：备受 Xcode 缓存、Node 依赖、Docker 镜像和本地大模型缓存折磨的人群。*
- 🔒 **Privacy Enthusiasts:** Who refuse to grant Full Disk Access to proprietary software with closed-source telemetry.
  * *隐私洁癖者：拒绝给闭源、带隐私收集的商业清理软件授予“完全磁盘访问权限 (FDA)”的人群。*

---

## 📊 How it compares / 同类对比

| | **AppSift** | CleanMyMac | Pearcleaner | Mole | OnyX |
|---|:---:|:---:|:---:|:---:|:---:|
| **Price / 价格** | **Free / 免费** | $40+/yr / 订阅制 | Free / 免费 | CLI free / GUI paid | Free / 免费 |
| **Open Source / 开源** | **Yes (MIT)** | No / 闭源 | Source-available¹ | CLI only | No / 闭源 |
| **No Telemetry / 零遥测** | **Yes / 是** | No / 否 | Yes / 是 | Yes / 是 | Yes / 是 |
| **No Subscription / 无订阅** | **Yes / 是** | No / 否 | Yes / 是 | — | Yes / 是 |
| **Native Mac GUI / 原生界面** | **Yes / 是** | Yes / 是 | Yes / 是 | Terminal-first | Yes / 是 |
| **Release Provenance / 源码可信度** | **Source + checksums** | Vendor release | Project release | Source | Project release |
| **App Uninstaller / 软件卸载** | **Yes / 是** | Yes / 是 | Yes / 是 | Partial | No / 否 |
| **Trash-first Removal / 回收站友好** | **Yes / 是** | Partial | Yes / 是 | Partial | No / 否 |
| **Honest Purgeable / 诚实不夸大** | **Yes / 是** | No / 否 | n/a | n/a | n/a |

<sub>¹ Pearcleaner is Apache 2.0 **+ Commons Clause** - source-available but not OSI-approved (you may not sell it). AppSift is true MIT. Comparison reflects publicly documented features as of 2026; corrections welcome via PR.</sub>

---

## 🤝 Our Promise / 我们的承诺

### English
A Mac cleaner asks for the deepest permission macOS grants—**Full Disk Access**—and then deletes your files. That demands a level of trust the category has spent twenty years burning. Here is the contract AppSift holds itself to:

*   **Recoverable by default, explicit when it is not.** App uninstall, App Reset, and Installation Files use Finder-semantic `NSWorkspace.recycle`, record every original-to-Trash mapping, and restore eligible items whenever destination permissions allow. Restore never overwrites an existing file; administrator-owned destinations are surfaced for Finder recovery instead of invoking a high-privilege shell. App actions never fall back to permanent deletion. Orphan cleanup also moves files to Trash. Reviewed system-cleaner items such as regenerable caches and logs are permanently deleted only through the separately confirmed cleaner flow.
*   **No telemetry, ever.** No analytics, no crash reporting, no "anonymous usage stats," no network calls to us. The app doesn't know you exist.
*   **Network use is explicit.** AppSift never contacts an AppSift account, analytics, or knowledge-base service. App Updates makes bounded requests only after you click Check for Updates: Apple Lookup for verified App Store receipts, local Homebrew commands for verified Casks, public HTTPS Sparkle appcasts, and electron-updater endpoints read from signed app bundles. GitHub checks use only the exact public owner/repository declared by that bundle; AppSift never guesses a repository or downloads its release assets.
*   **No fake urgency.** No dramatized "47 GB of junk detected!" badge, no red alarm counters, no "your Mac is at risk." We show you neutral facts and let you decide.
*   **No overpromising.** We don't claim to "reclaim purgeable space," "boost RAM," or "speed up your Mac" - things no app can reliably do. See the purgeable-space note below.
*   **You review before anything is removed.** Nothing is auto-deleted. Every item shows its real path with Reveal-in-Finder, and high-risk system paths are hard-excluded in code.
*   **Auditable.** Every app-file candidate shows the evidence that matched it. Each report records whether the action was an uninstall, App Reset, or related-file removal; it also records moved, already-missing, failed, protected, and restored items, and can be exported locally as JSON with a reproducible SHA-256 integrity checksum (explicitly not a digital signature). Reports contain paths, never file contents, are never uploaded, and can be cleared at any time. The exact decision code remains open in [`AppSift/Services`](AppSift/Services) and [`AppSift/Logic/Scanning`](AppSift/Logic/Scanning).

If AppSift ever adds telemetry, a paywall on core features, or a fear-based scan, it will have become the thing it was built to replace. Hold us to this.

### 简体中文
清理软件需要 macOS 最深层的权限——**完全磁盘访问权限 (Full Disk Access)**——然后去删除你的文件。这需要极高的信任度。以下是 AppSift 坚守的契约，你可以在源码中验证每一行：

*   **默认可恢复，不可恢复时明确提示**：卸载、重置和清理操作全部采用 Finder 语义的回收机制，保存映射记录，可随时在回收站还原。还原绝不覆盖已有文件，管理员权限目标会提示通过 Finder 恢复以避免调用高权 Shell。卸载动作绝不退化为永久删除。孤儿文件清理同样移入回收站。仅系统清理在单独确认后执行永久删除。
*   **绝对零遥测**：无分析、无崩溃报告、无“匿名数据收集”。软件完全在本地离线运行。
*   **网络使用完全透明**：只有在你手动点击“检查更新”时，才会发起受限的网络请求。检查包括 App Store 收据、Homebrew Cask 信息以及 Github 官方 Releases 链接，绝不请求未知服务器或后台静默下载安装包。
*   **绝无虚假恐吓**：不搞红色的警报弹窗，不弹虚假的“系统处于危险中”等夸大词汇，只呈现客观数据，由你自行决定。
*   **从不夸大其词**：不吹嘘能“释放可擦除空间”、“清理内存”或“加速 Mac”（这些在现代 macOS 上无法被第三方应用可靠实现）。
*   **清理前可完全预览**：没有任何自动删除行为。每一项文件都支持在 Finder 中显示，并内置了针对敏感系统路径的硬编码拦截。
*   **完全可审计**：所有扫描和判断逻辑在 [`AppSift/Services`](AppSift/Services) 和 [`AppSift/Logic/Scanning`](AppSift/Logic/Scanning) 中全部开源，接受全球开发者监督。可本地导出包含 SHA-256 完整性哈希（非数字签名）的无内容路径报告。

---

## 🛠️ Advanced Source Build Guide / 进阶源码编译指南

If you want to build AppSift from source manually:
*如果你想手动从源码编译 AppSift：*

```bash
brew install xcodegen
git clone https://github.com/GravityPoet/AppSift.git
cd AppSift
xcodegen generate
./script/build_and_run.sh
```

The runner creates a project-specific `AppSift Local Code Signing` identity in
your login keychain when needed. It is a local self-signed identity, not an
Apple Developer ID, and keeps AppSift's macOS privacy identity stable across
source rebuilds on that Mac. The private key never enters the repository.

The development runner reuses one hidden, Spotlight-excluded DerivedData location and stays attached
while the debug app runs. When you quit it, the runner unregisters and removes
the generated app bundle, so `/Applications/AppSift.app` remains the only
AppSift entry in Spotlight and app launchers. Run
`./script/build_and_run.sh --clean` to remove the reusable build cache too.
The customer release scripts likewise keep only the final DMG/ZIP/status files
and remove their temporary App bundle and build root on every exit.

To build a Universal local release, back up the existing installation, and
atomically replace `/Applications/AppSift.app` with the same stable identity:

```bash
./scripts/install-local.sh
```

The first migration from an ad-hoc build requires one final Full Disk Access
grant. Later local rebuilds retain the same code requirement as long as the
`AppSift Local Code Signing` identity remains in the login keychain.

Customer Release builds currently use that same identity:

```bash
./scripts/release-self-signed.sh
```

The legacy `./scripts/release-local.sh` entry point forwards to this same
self-signed builder, so it cannot silently switch customer builds to another
certificate.

This produces a Universal self-signed DMG and ZIP plus an explicit signing
status file under `build/`. These artifacts are **not Apple-notarized**, so a
customer may need to use Finder's **Open** context-menu action on first launch.
The Developer ID GitHub workflow is manual-only and reserved for a future,
explicit certificate migration; running it would change the macOS privacy
identity and require one migration-time permission grant.

---

## ⚙️ Detailed Feature Breakdown / 功能深度详解


### App Uninstaller
Discovers apps in `/Applications` and `~/Applications`, then scans a bounded set of relevant Library roots using exact app names, structured bundle identities, container metadata, and identifiers from verified developer entitlements. Three sensitivity tiers - Strict, Enhanced, Deep - control which of those evidence sources may be used, and every displayed candidate explains which rule matched it. A second ownership boundary protects other apps, shared app groups, shared identities, and ambiguous matches instead of silently deleting them. Generic backup, archive, snapshot, recovery, and restore hosts maintained by other tools stay protected when only a display name or partial identifier matches; only a full structured bundle identity, verified app-specific entitlement, container metadata, or explicit app rule can bypass that boundary. A Team ID alone never authorizes removal because one publisher may ship multiple apps. AppSift also builds a read-only App Group relationship map: two apps are linked only when both have valid developer signatures, the same Team ID, and the exact same signed group identifier. The detail sheet names every declaring app, inspects the expected container and Application Scripts paths without following symlinks, and explicitly distinguishes declared access from evidence of recent use. The same graph is available through `AppSift app-relationships` and `AppSift app-relationships --json`. Before removal, AppSift also verifies installation provenance: Mac App Store requires both an App Store certificate and a bounded local receipt; Homebrew Cask requires an exact receipt artifact plus a Caskroom link or matching signed bundle; and a bundled uninstaller is offered only when its valid Team ID matches the selected app. For apps installed by a macOS Installer package, AppSift queries the system receipt database through read-only `pkgutil` commands and requires the receipt payload to cover the selected App. Generic parent folders are collapsed into real external component roots, and the detail view shows each present component's path, payload count, receipt-only/shared/unverified ownership, other receipt IDs, and system-sensitive status. Every external component remains protected evidence and is never imported into the removal selection. Homebrew `zap` paths are likewise shown only as a count and are never treated as removal authorization, while an official uninstaller is revalidated immediately before opening. Uninstall and App Reset both use the system Trash and create a complete local report covering moved, missing, failed, protected, and restored items. App Reset first quits the target, keeps its application bundle installed, and accepts only reviewed current-user data below a narrow `~/Library` allow-list; executable packages, shared group containers, launch items, command-line tools, and system-wide components remain untouched. Removal History can restore eligible items, export a path-only JSON report with an integrity checksum, or clear reports without touching Trash. Apple system apps are excluded automatically. You can also right-click any app in Finder and choose **Services → Uninstall with AppSift** or **Reset with AppSift**; reset requests preselect only the narrower reviewed user-data scope.

### Application Usage
Reads Apple's public Spotlight `kMDItemLastUsedDate` metadata locally and adds a sortable **Last Opened** column plus 30, 90, and 180-day unused filters to Installed Apps. AppSift classifies an app as unused only when a real last-opened date crosses the selected threshold. Missing metadata and future/invalid timestamps remain **No reliable record** instead of being misrepresented as “never opened,” and neither state selects an app for removal.

The same read-only evidence is available through `AppSift app-usage [--days 30|90|180]` and `AppSift app-usage --json`. JSON includes the threshold, summary counts, explicit status for every app, and `null` for unavailable last-used evidence. No usage inventory leaves the Mac.

### App Updates
Checks updates only when requested and chooses a source from evidence on the Mac rather than a private vendor database. Mac App Store results require an App Store signature, a bounded receipt, a Spotlight product ID, and an Apple Lookup bundle-ID match. Homebrew results require the same verified Cask receipt and Caskroom artifact used by the uninstaller, then run a token-bounded `brew outdated` query without silently refreshing taps. Sparkle apps require a valid developer signature and a public HTTPS `SUFeedURL`; AppSift parses a size-bounded appcast and filters stable updates for the current macOS and hardware.

Electron apps are supported when a developer-signed bundle contains an exact `Contents/Resources/app-update.yml`. AppSift accepts only public HTTPS `generic` providers or an exact public GitHub owner/repository, rejects credentials, request headers, private providers, custom GitHub hosts, local/private network targets, and ambiguous metadata, and reads both modern `files[]` and legacy `path` + `sha512` `latest-mac.yml` formats. Squirrel.Mac is shown as local framework evidence, not treated as update authorization. Staged releases and releases requiring a newer Darwin version are reported for review rather than claimed as available to every Mac. GitHub release identity, tag, metadata asset, ZIP name, and release page must all remain within the declared repository.

Before any action, AppSift rechecks the app path, developer signature, Team ID, embedded updater configuration, and remote release identity. App Store opens the product page, Homebrew runs its official targeted upgrade only after confirmation, Sparkle uses the target app's own key/signature validation and standard update UI, a generic Electron source opens the app, and GitHub opens only the verified release page. AppSift never downloads or installs an arbitrary release asset itself. The same evidence-backed inventory is available through `AppSift app-updates` and `AppSift app-updates --json`.

### Installation Files
Finds indexed DMG, PKG, MPKG, XIP, and verified single-App ZIP files without mounting disk images, executing installers, or extracting archives and without relying on a private vendor database. Each result shows its real path plus available Spotlight, Uniform Type, signature, notarization, quarantine-source, package-payload, and archive-content evidence. A PKG or MPKG is associated with an installed app only when both its payload App name and installer Team ID match.

ZIP inspection uses a bounded, read-only system listing and accepts only a complete archive with one outer `.app`, its `Contents/Info.plist`, and a MacOS executable; nested helper apps are allowed only under that same outer bundle. Ordinary archives, multiple top-level apps, traversal or absolute paths, invalid UTF-8, count mismatches, oversized/truncated output, and archives outside Downloads/Desktop without a safe quarantine origin are ignored. AppSift never presents the ZIP itself as signed, because the archive container cannot carry a macOS code signature.

Nothing is selected automatically. App-managed Library paths require a per-file review and are never included in Select All; other volumes or owners, hard links, symlinks, and files outside the current user's home remain hard-protected. Before moving an explicitly selected item, AppSift rechecks its exact filesystem fingerprint and safety boundary, uses the macOS Trash, persists a private bounded undo history, and restores the file automatically if that history cannot be saved. Restored paths are inspected directly while Spotlight catches up, so Undo is reflected immediately. The same read-only inventory is available through `AppSift installation-files` and `AppSift installation-files --json`.

### Update and installer compatibility matrix

This table separates code-path coverage from real hardware coverage so a compiled slice is never presented as a successful runtime test.

| Capability | Apple silicon | Intel | Universal / mixed releases | Compatibility evidence |
|---|:---:|:---:|:---:|---|
| AppSift itself | Native `arm64` | Native `x86_64` | Universal binary | Release build + `lipo`; XCTest runs on the current Mac. Intel runtime remains an external-matrix check when no Intel host is attached. |
| Mac App Store updates | Yes | Yes | Apple-managed | Receipt, product ID, bundle match; App Store performs delivery. |
| Homebrew Cask updates | `/opt/homebrew` | `/usr/local` | Cask-managed | Exact receipt/artifact and allow-listed executable; Homebrew performs the targeted upgrade. |
| Sparkle updates | Yes | Yes | Yes | Stable appcast items are filtered by minimum system version and hardware requirements; the target app validates and installs. |
| Electron generic | Yes | Yes | Yes, including architecture-specific ZIP metadata | Signed `app-update.yml`; modern `files[]` and legacy `path` metadata fixtures. AppSift reports metadata and opens the app—it never guesses the correct asset architecture. |
| Electron GitHub Releases | Yes | Yes | Yes, including architecture-specific ZIP metadata | Exact owner/repository/tag/release/metadata identity fixtures. AppSift opens the verified release page and does not download an asset. |
| DMG / PKG / MPKG / XIP inventory | Architecture-neutral | Architecture-neutral | Architecture-neutral | Read-only metadata, signature, quarantine, and package-payload inspection; nothing is executed. |
| Single-App ZIP inventory | Architecture-neutral | Architecture-neutral | Architecture-neutral | Real `ditto` fixture plus malicious/ambiguous listing fixtures; the archive is listed but never extracted. |

The matrix is intentionally extensible: each future source must identify its local trust evidence, supported metadata format, architecture decision owner, real-host status, and failure behavior before it can be marked supported.

### Startup Items
Shows Login Items, background tasks, LaunchAgents, and LaunchDaemons in a searchable system view. Results join macOS Background Task Management records with bounded, non-symlink launchd property lists and Apple's local attribution metadata when available. Each row shows status, scope, identifier, path, and the evidence source; missing files and items awaiting approval are explicit. Modern background items, system LaunchAgents, and LaunchDaemons remain read-only and are handed off to the official macOS Login Items settings.

For traditional property lists directly inside the current user's `~/Library/LaunchAgents`, AppSift can safely disable or enable the service without deleting its plist. Every action revalidates the direct-child path, current-user ownership, non-symlink regular-file type, write permissions, explicit `Label`, and SHA-256 before using fixed `/bin/launchctl` commands. AppSift records the original disabled and loaded state in a local `0600` history file, supports stack-ordered undo, refuses undo after the plist changes, and automatically restores the previous launchd state if the history cannot be saved. Startup control is never coupled to app removal.

### Extensions
Builds a single evidence-backed inventory of third-party App, Safari and supported browser, Finder, Share, widget, system, preference pane, screen saver, Quick Look, Internet plug-in, and kernel extensions. Results come from public macOS registries, local browser extension metadata and state fields, on-disk bundles, containing apps, and code signatures; unreadable sources are reported instead of guessed. AppSift opens the owning browser or Apple's Login Items & Extensions settings for changes and only reveals legacy bundles in Finder—it does not directly delete protected extension components.

### Privacy Permissions
Audits locally recorded macOS privacy decisions together with the usage reasons declared in installed apps' `Info.plist` files. AppSift opens TCC databases with SQLite read-only/query-only flags, refuses symlinked database files, validates the minimum schema before reading, bounds every result set, and reports missing, unreadable, or unsupported sources instead of presenting an empty inventory as complete. A declared usage reason is shown separately and is never treated as proof that access was granted or used. Unknown future TCC services remain visible evidence but cannot become command arguments.

AppSift never writes a TCC database directly. For bundle-identified apps and only Apple-documented services, **Reset Decision** invokes the fixed system `/usr/bin/tccutil reset <service> <bundle-id>` command after revalidating the current scan record. Reset neither grants nor denies access; it makes macOS ask again the next time the app requests that permission. Path-based clients, stale UI records, malformed bundle identifiers, and undocumented services remain read-only. The same inventory is available through `AppSift app-permissions` and `AppSift app-permissions --json`.

### Default Applications
Builds a searchable inventory of file types from common UTTypes and installed apps' document declarations, then asks LaunchServices for the current handler and every registered alternative. Changes use Apple's public `NSWorkspace.setDefaultApplication` API, revalidate the current and target apps immediately before the request, honor macOS consent prompts, verify the resulting handler, and persist a private undo record. If the undo record cannot be saved, AppSift restores the previous default automatically instead of leaving an untracked change.

### Orphan Finder
Walks `~/Library` and surfaces files left behind by apps that no longer exist on disk. The matcher compares against bundle identifiers and normalized names of every installed app, so a leftover `~/Library/Containers/com.foo.bar` from an app you deleted in 2022 shows up clearly.

### System Cleaner
Smart Scan runs every category in parallel. Each category is its own deliberate scanner:

- **System Junk** - system caches, logs, temp files
- **User Cache** - dynamically discovered, no hardcoded app list
- **AI Apps** - Ollama and LM Studio logs, caches, opt-in history cleanup
- **Mail Files** - downloaded mail attachments
- **Trash Bins** - empties all bins, including external volumes
- **Large & Old Files** - >100 MB or older than 1 year (never auto-selected)
- **Xcode Junk** - DerivedData, Archives, simulator caches
- **Brew Cache** - respects custom `HOMEBREW_CACHE`
- **Node Cache** - npm, yarn classic, pnpm content-addressable store
- **Docker Cache** - images, containers, build cache

> **On "purgeable space":** AppSift shows your APFS purgeable space in the storage breakdown for transparency, but it deliberately does **not** list it as junk to delete. Purgeable space is reserved and reclaimed by macOS itself - no third-party app can reliably free it, and even the Finder's purgeable figure is known to be inaccurate. Cleaners that claim to "reclaim purgeable space" are overpromising. We'd rather be honest than impressive.

### Scheduled Cleaning
Optional. Configurable interval (hourly to monthly), with auto-clean threshold so background runs only fire when there's something meaningful to remove.

## Permissions

AppSift needs **Full Disk Access** to read the locations macOS hides from every app by default - Mail downloads, Safari data, the TCC database, protected app containers. Without it, the cleanup categories miss roughly 70% of what they could find and app uninstalls leave behind everything in `~/Library/Containers`.

The first-launch onboarding walks you through granting it with an animated preview of the exact toggle you need to flip. If you skip it, the dashboard surfaces a single-click "Set up" pill. If a cleanup fails because of a permission issue, AppSift opens System Settings, reveals its bundle in Finder so you can drag it into the FDA list, polls the permission state every second, and auto-retries the failed batch the moment you grant access. You never have to re-select anything.

What AppSift does *not* do:
- It does not collect telemetry, crash reports, or usage analytics.
- Core cleaning, uninstall, reset, startup-item inspection, and local history work without a network connection. App Updates contacts only a verified Apple or vendor source after you request a check.
- It does not upload data or move it outside your Mac. Recoverable removals go only to the macOS Trash.

## Troubleshooting

### Launchpad / Dock shows a stale or dull AppSift icon

macOS aggressively caches app icons in LaunchServices. After a Homebrew **reinstall or upgrade** the Dock and Launchpad can keep showing the old cached icon. AppSift's cask now runs `lsregister -f` on install to refresh it automatically, but if a stale icon persists, reset the cache manually:

```bash
# Clear the icon caches and rebuild the LaunchServices database
sudo rm -rfv /Library/Caches/com.apple.iconservices.store
sudo find /private/var/folders/ \( -name com.apple.dock.iconcache -or -name com.apple.iconservices \) -exec rm -rfv {} \; 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -kill -r -domain local -domain user -domain system
killall Dock; killall Finder
```

Give it a minute to re-seed, then open AppSift once. If it still sticks, a restart (or Safe Mode boot) forces a full rebuild.

## Screenshots

| Onboarding | App Uninstaller |
|---|---|
| ![Onboarding](screenshots/onboarding.png) | ![App Uninstaller](screenshots/app-uninstaller.png) |

| System Junk | Xcode Junk |
|---|---|
| ![System Junk](screenshots/system-junk.png) | ![Xcode Junk](screenshots/xcode-junk.png) |

| User Cache |
|---|
| ![User Cache](screenshots/user-cache.png) |

## Architecture

```
AppSift/
  Logic/Scanning/     - Heuristic scan engine, locations database, conditions
  Logic/Utilities/    - Structured logging
  Models/             - Data models, typed errors
  Services/           - Scan engine, cleaning engine, permission coordinator, scheduler
  ViewModels/         - Centralized app state
  Views/              - Native SwiftUI views
    Apps/             - App uninstaller views
    Components/       - Shared components (FDA demo, permission sheet, theme)
    Orphans/          - Orphan finder
    Settings/         - Native Form-based settings
```

Key components:
- **AppPathFinder** - Bounded, cancellable evidence matcher for app-related files
- **AppRelationshipScanner** - Bounded signed App Group graph requiring an exact Team ID and group-identifier match, with non-following local path inspection
- **Locations** - Curated macOS roots compressed into a small non-overlapping scan plan
- **Conditions** - 25 per-app matching rules for edge cases (Xcode, Chrome, VS Code, etc.)
- **PermissionCoordinator** - Single source of truth for FDA prompts, polling, and post-grant retries
- **FullDiskAccessManager** - TCC probe + registration; broad probe paths (Mail, Safari, Messages, AddressBook, Calendars) so macOS catalogs the bundle reliably
- **AppFileTrashService** - Finder-semantic app removal with original-to-Trash receipts and no permanent-delete fallback
- **AppInstallationInspector** - Read-only Mac App Store, Homebrew Cask, and same-developer official-uninstaller provenance with bounded parsing and click-time revalidation
- **AppUpdateScanner** - User-triggered App Store, Homebrew Cask, HTTPS Sparkle, signed electron-updater generic, and exact GitHub Release checks with bounded responses, source evidence, compatibility filtering, and action-time revalidation
- **AppUsageAnalyzer** - Local Spotlight last-opened evidence, conservative unused/unknown classification, stable sorting, threshold filters, and explicit CLI/JSON reporting
- **InstallationFileScanner / InstallationFileController** - Evidence-backed DMG, PKG, MPKG, XIP, and single-App ZIP inventory with bounded read-only archive listing, protected path boundaries, click-time fingerprint checks, Trash-first removal, and local undo
- **StartupItemScanner** - Read-only Background Task Management plus launchd inventory with status, ownership attribution, symlink rejection, and bounded process/file output
- **StartupItemController** - Current-user legacy LaunchAgent enable/disable with fixed launchctl commands, pre-action identity checks, exact-state rollback, and local undo history
- **AppRemovalReportExporter** - Local path-only JSON audit reports with explicit outcomes, safety exclusions, and a reproducible SHA-256 checksum
- **CleaningEngine** - Symlink-resistant system-cleaner deletion with an allow-list, NSAppleScript-based admin escalation for root-owned cleaner items, and NUL-separated path staging for xargs

## Security

- Symlink attack prevention: paths are resolved before validation, re-resolved immediately before unlink to close TOCTOU windows.
- Allow-list cleaning: a path that doesn't sit inside an explicit safe-root is refused, even for the user-level pass.
- Administrator escalation re-validates the normal cleaner allow-list and is never used by the app-uninstall flow.
- System app protection: Apple's bundles cannot be uninstalled, regardless of selection.
- All destructive operations require explicit confirmation by default. The toggle that disables that confirmation is buried in Settings.
- Update-network responses are size- and time-bounded; non-HTTPS, credentialed, localhost, private-IP, and local-network Sparkle or Electron targets are refused. Electron private providers, tokens, request headers, custom GitHub hosts, and cross-repository release URLs are refused. Homebrew tokens and executable paths are allow-listed before process launch.
- Installation files are never mounted, executed, or expanded. ZIPs are inspected only through a bounded read-only listing. Removal accepts only revalidated, current-user regular files inside the home data volume, rejects symlinks and hard links, and rolls the Trash move back if its private undo history cannot be persisted.
- Startup control never invokes a shell or administrator access. Only a current-user, direct-child, non-symlink `~/Library/LaunchAgents/*.plist` with a matching explicit label and safe permissions can be changed; modern and system items stay read-only.

If you find a vulnerability, please open a private security advisory rather than a public issue.

## Contributing

Pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

Especially welcome:
- Per-category size and date filter presets
- Wider XCTest coverage for `AppState` and the scan engine
- Translations beyond the current set (en, ar, es, ja, pt-BR, zh-Hans, zh-Hant)
- App icon design

## Acknowledgments

- **[@nguyenhuy158](https://github.com/nguyenhuy158)** - Search and filter feature ([#18](https://github.com/momenbasel/PureMac/issues/18), [#29](https://github.com/momenbasel/PureMac/pull/29))
- **[@edufalcao](https://github.com/edufalcao)** - Cleaning safety guards and confirmation dialogs ([#30](https://github.com/momenbasel/PureMac/pull/30))
- **[@zeck00](https://github.com/zeck00)** - UI overhaul ([#31](https://github.com/momenbasel/PureMac/pull/31)), app uninstaller with system app protection ([#32](https://github.com/momenbasel/PureMac/pull/32)), onboarding experience ([#33](https://github.com/momenbasel/PureMac/pull/33))
- **[@0x-man](https://github.com/0x-man)** - Symlink security vulnerability report ([#25](https://github.com/momenbasel/PureMac/issues/25))
- **[@ansidev](https://github.com/ansidev)** - Checkbox interaction bug report ([#34](https://github.com/momenbasel/PureMac/issues/34))
- **[@fengcheng01](https://github.com/fengcheng01)** - App uninstaller feature request ([#28](https://github.com/momenbasel/PureMac/issues/28))
- **[@scholzfuni](https://github.com/scholzfuni)** - Modularization proposal ([#23](https://github.com/momenbasel/PureMac/issues/23))
- **[@Zonharo](https://github.com/Zonharo)** - In-app auto-update request ([#94](https://github.com/momenbasel/PureMac/issues/94))

## Attribution

AppSift is an independent product maintained by **GravityPoet**. It began as a
fork of [PureMac](https://github.com/momenbasel/PureMac), and the original
PureMac contributors and MIT license notice are retained in this repository.
AppSift-specific changes are Copyright © 2026 GravityPoet. This acknowledgment
does not imply that the PureMac contributors endorse or maintain AppSift.

## Star History

If AppSift saved you some disk space, a star helps other people find it.

<a href="https://star-history.com/#GravityPoet/AppSift&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=GravityPoet/AppSift&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=GravityPoet/AppSift&type=Date" />
    <img alt="AppSift star history chart" src="https://api.star-history.com/svg?repos=GravityPoet/AppSift&type=Date" width="720" />
  </picture>
</a>

## License

MIT. See [LICENSE](LICENSE). You may use, fork, and ship AppSift under your own name; retain the original PureMac notice and the MIT terms.
