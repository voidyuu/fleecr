<p align="center">
  <img src="Resources/AppIcon/fleecr-icon-1024.png" width="140" alt="fleecr logo" />
</p>

<h1 align="center">fleecr</h1>

<p align="center">
  专为 <a href="https://herdr.dev/">herdr</a> 打造的原生 macOS 控制台，将你的 AI 编程智能体与实时终端整合于一体。
</p>

<p align="center">
  <a href="https://github.com/voidyuu/herdrm/releases/latest"><img src="https://img.shields.io/github/v/release/voidyuu/herdrm?color=blue" alt="最新版本" /></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-007AFF?logo=apple&logoColor=white" alt="macOS 14.0+" />
  <img src="https://img.shields.io/badge/终端核心-libghostty-FF6B6B" alt="libghostty" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/开源协议-MIT-green" alt="协议: MIT" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README_zh.md">简体中文</a>
</p>

---

<p align="center">
  <img src=".github/assets/screenshot.png" alt="fleecr 预览" width="800" />
</p>

## ✨ 特性亮点

- **⚡ 100% 纯原生 & 极速** — 基于 SwiftUI 与 AppKit 打造。零 Electron、瞬时启动、极低内存占用。
- **💻 基于 [libghostty](https://github.com/ghostty-org/ghostty) 终端引擎** — 硬件加速终端模拟，真实 PTY 直连、原生文本选区、Nerd Fonts 符号支持与 20+ 款精美内置配色主题。
- **🤖 通用 AI 编程智能体中心** — 开箱即用支持 Claude Code、Codex、Cursor、Gemini、Grok、OpenCode、pi、Kimi 及各类自定义 CLI 智能体。
- **🌐 多设备统一管理** — 在同一侧边栏中无缝连接本地与远程 SSH 机器（支持密钥、密码与 Tailscale），断线自动静默重连。
- **📁 智能附件与文件管理** — 支持直接粘贴（⌘V）或拖拽图片/文件至智能体终端，内置双栏远程文件对比与传输。
- **⌨️ 键控流交互** — 全局 ⌘K 快速搜索检索、多向分屏（⌘D / ⇧⌘D）、标签循环（⌃⇥ / ⌃⇧⇥）以及后台状态感知通知。

## 📦 安装指南

**Homebrew**
```sh
brew install owo-network/brew/fleecr
```

**手动下载**  
从 [Releases](https://github.com/voidyuu/herdrm/releases) 下载最新的通用二进制文件，解压后将 `Fleecr.app` 拖入 `/Applications` 文件夹即可。应用内置基于 Sparkle 的自动更新。

## 📋 运行要求

- macOS 14.0+ (Sonoma 或更高版本)
- [herdr](https://herdr.dev/)（如果本地未运行，fleecr 会自动尝试启动后台服务）

## 🔨 从源码构建

```sh
brew install xcodegen
make build   # 构建 Fleecr.app
make run     # 运行应用
```

## 🙏 致谢

- [missuo/herdrm](https://github.com/missuo/herdrm) — 本项目基于的原型项目。
- [herdr](https://herdr.dev/) — 提供底层 Agent 生命周期、PTY 与会话持久化的核心服务。
- [libghostty](https://github.com/ghostty-org/ghostty) — 极速的现代终端模拟引擎。
- [s1dashu/ip-as-logo-skill](https://github.com/s1dashu/ip-as-logo-skill) — 应用图标设计。

## 📄 开源协议

本项目采用 [MIT 许可证](LICENSE) 开源。
