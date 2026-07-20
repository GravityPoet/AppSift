<p align="center">
  <img src="../screenshot.png" alt="AppSift" width="700">
</p>

<p align="center">
  <a href="../README.md">English</a> |
  <a href="README.ar.md">العربية</a> |
  <a href="README.es.md">Español</a> |
  <a href="README.ja.md">日本語</a> |
  <b>简体中文</b> |
  <a href="README.zh-Hant.md">繁體中文</a>
</p>

<p align="center">
  <img src="assets/icon.png" alt="AppSift eraser app icon" width="128">
</p>

<h1 align="center">AppSift</h1>

<p align="center"><b>AppSift — Cleaner &amp; Uninstaller</b></p>

<p align="center">
  <b>免费、开源的 macOS 应用管理器与系统清理工具。</b><br>
  彻底卸载应用。查找孤立文件。清理系统垃圾。<br>
  无订阅。无遥测。无数据收集。
</p>

<p align="center">
  <a href="https://github.com/GravityPoet/AppSift/releases/latest"><img src="https://img.shields.io/github/v/release/GravityPoet/AppSift?style=flat-square&label=%E4%B8%8B%E8%BD%BD" alt="最新版本"></a>
  <a href="https://github.com/GravityPoet/AppSift/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/GravityPoet/AppSift/build.yml?style=flat-square&label=Build" alt="构建状态"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/GravityPoet/AppSift?style=flat-square" alt="MIT 许可证"></a>
  <a href="https://github.com/GravityPoet/AppSift/stargazers"><img src="https://img.shields.io/github/stars/GravityPoet/AppSift?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/GravityPoet/AppSift/releases"><img src="https://img.shields.io/github/downloads/GravityPoet/AppSift/total?style=flat-square&label=%E4%B8%8B%E8%BD%BD%E9%87%8F" alt="下载量"></a>
</p>

<p align="center">
  <a href="#安装">安装</a> -
  <a href="#功能">功能</a> -
  <a href="#截图">截图</a> -
  <a href="#贡献">贡献</a>
</p>

---

## 安装

### Homebrew（推荐）

```bash
brew update
brew tap GravityPoet/tap
brew install --cask appsift
```

### 直接下载

从 [Releases](https://github.com/GravityPoet/AppSift/releases/latest) 下载最新的 `.dmg`，打开后将 AppSift 拖到 `/Applications` 目录。

> 每个版本的发布说明会注明签名、公证状态和 SHA-256 校验值。

> AppSift 是由 GravityPoet 独立维护的产品，最初基于 [PureMac](https://github.com/momenbasel/PureMac) 分支开发。原项目致谢与许可证见[归属说明](../README.md#attribution)。

### 从源码构建

```bash
brew install xcodegen
git clone https://github.com/GravityPoet/AppSift.git
cd AppSift
xcodegen generate
./script/build_and_run.sh
```

## 功能

### 应用卸载器
- 从 `/Applications` 和 `~/Applications` 发现所有已安装应用
- 采用有界扫描，并以精确应用名称、结构化 Bundle ID、容器元数据和已验证的 entitlement 作为归属证据
- **3 种灵敏度**:严格(安全)、增强(平衡)、深度(彻底)
- 展示所有相关文件:缓存、偏好设置、容器、日志、支持文件、启动代理
- 每个候选项都会说明命中它的归属证据；共享或不确定的项目会作为受保护项单独展示
- 卸载只移到废纸篓，并保存包含已移动、已缺失、失败、受保护和已恢复项目的本地报告；可导出带 SHA-256 完整性校验的路径 JSON，也可随时清空报告而不改动废纸篓
- 系统应用保护 — 自动排除 Apple 系统应用，避免误删
- 主从视图:左侧为应用列表,右侧为发现的文件

### 孤立文件查找
- 检测 `~/Library` 中已卸载应用残留的文件
- 将 Library 内容与所有已安装应用的标识符进行比对
- 一键清理孤立文件

### 系统清理
- **智能扫描** — 一键扫描所有类别
- **系统垃圾** — 系统缓存、日志和临时文件
- **用户缓存** — 动态发现所有应用缓存(无需硬编码应用列表)
- **AI 应用** — Ollama 和 LM Studio 日志、缓存，以及可选的本地历史记录清理
- **邮件附件** — 已下载的邮件附件
- **废纸篓** — 清空所有废纸篓
- **大文件与旧文件** — 超过 100 MB 或超过 1 年的文件
- **可清除空间** — 检测 APFS 可清除磁盘空间
- **Xcode 垃圾** — DerivedData、Archives、模拟器缓存
- **Brew 缓存** — Homebrew 下载缓存(可识别自定义 HOMEBREW_CACHE)
- **定时清理** — 按可配置的间隔自动扫描

### 原生 macOS 体验
- 使用 SwiftUI 和原生 macOS 组件构建
- `NavigationSplitView`、`Toggle`、`ProgressView`、`Form`、`GroupBox`、`Table`
- 自动遵循系统浅色/深色模式
- 无自定义渐变、发光或 Web 应用样式
- 首次启动引导,支持完整磁盘访问设置

### 安全性
- 所有破坏性操作前都有确认对话框
- 防御符号链接攻击 — 删除前解析并验证路径
- 系统应用保护 — Apple 应用无法被卸载
- 大文件与旧文件永远不会被自动选中
- AI 提示和对话历史记录会显示供用户检查，但永远不会自动选中
- 通过 `os.log` 进行结构化日志记录(可在“控制台”应用中查看)

## 截图

| 引导 | 应用卸载器 |
|---|---|
| ![引导](../screenshots/onboarding.png) | ![应用卸载器](../screenshots/app-uninstaller.png) |

| 系统垃圾 | Xcode 垃圾 |
|---|---|
| ![系统垃圾](../screenshots/system-junk.png) | ![Xcode 垃圾](../screenshots/xcode-junk.png) |

| 用户缓存 |
|---|
| ![用户缓存](../screenshots/user-cache.png) |

## 架构

```
AppSift/
  Logic/Scanning/     - 启发式扫描引擎、位置数据库、条件
  Logic/Utilities/    - 结构化日志
  Models/             - 数据模型、类型化错误
  Services/           - 扫描引擎、清理引擎、调度器
  ViewModels/         - 集中式应用状态
  Views/              - 原生 SwiftUI 视图
    Apps/             - 应用卸载器视图
    Cleaning/         - 智能扫描与分类视图
    Orphans/          - 孤立文件查找
    Settings/         - 基于原生 Form 的设置
    Components/       - 共享组件
```

核心组件:
- **AppPathFinder** — 可取消、有界的应用文件归属证据匹配器
- **Locations** — 会压缩为少量不重叠扫描计划的精选 macOS 路径
- **Conditions** — 25 条针对特殊情况的应用级匹配规则(Xcode、Chrome、VS Code 等)
- **AppInfoFetcher** — 使用 Spotlight 元数据,并以 Info.plist 作为回退的应用发现
- **Logger** — 基于 Apple `os.log` 的统一日志

## 贡献

欢迎贡献。请参阅 [CONTRIBUTING.md](../CONTRIBUTING.md) 了解指南。

特别欢迎的贡献方向:
- 分类视图中的大小/日期过滤器预设
- AppState 与扫描引擎的 XCTest 覆盖
- 本地化(其他语言)
- 应用图标设计

## 许可证

MIT 许可证。详情请参阅 [LICENSE](../LICENSE)。
