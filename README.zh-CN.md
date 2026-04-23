# go2cmux

[English](README.md) | 简体中文

`go2cmux` 是一个很小的 macOS 辅助应用，用来把 Finder 当前所在的文件夹直接打开到 [`cmux`](https://github.com/manaflow-ai/cmux) 里。

它的使用方式和 Go2Shell 这类工具类似：把 app 拖到 Finder 工具栏，点击一下，就能从当前 Finder 目录直接跳进终端应用。不同的是，这个项目的目标终端是 `cmux`。

## 它能做什么

当你在 Finder 工具栏点击 `go2cmux` 时，它会：

1. 读取 Finder 当前所在的文件夹
2. 在需要时启动 `cmux`
3. 把这个文件夹作为新的 `cmux` workspace 打开

当前实现保持得很小而专注：

- 不修改 `cmux` 源码
- 不依赖本地开发版 `cmux`
- 直接面向正式安装的 `cmux.app`

## 为什么要做这个项目

`cmux` 本身已经支持打开文件夹，但一些老牌 Finder 辅助工具通常只认识 Terminal.app、iTerm 这类传统终端，不认识 `cmux`。  
`go2cmux` 的作用，就是补上这个 Finder 到 `cmux` 的启动入口。

## 运行要求

- macOS
- 本地已经安装 `cmux`
- 如果你想从源码构建，需要安装 Xcode 或 Apple Command Line Tools

运行时，`go2cmux` 会按下面的顺序查找 `cmux.app`：

1. 先按 bundle identifier `com.cmuxterm.app` 查找系统已登记的应用
2. `/Applications/cmux.app`
3. `~/Applications/cmux.app`

## 权限说明

`go2cmux` 通过 Apple Events / 自动化能力与下面两个应用通信：

- Finder：读取当前文件夹
- `cmux`：创建 workspace

第一次使用时，macOS 可能会弹出权限提示，要求允许 `go2cmux` 控制 Finder 和 `cmux`。  
如果权限被拒绝，app 会尽量给出更明确的错误提示，告诉你缺的是哪一个权限。

## 构建

仓库里已经包含一个简单的构建脚本，可以直接生成带 ad-hoc 签名的 app bundle：

```bash
./scripts/build.sh
```

构建产物在：

```text
build/go2cmux.app
```

这个脚本会做三件事：

- 把 `Resources/Info.plist` 复制进 app bundle
- 用 `swiftc` 编译 `go2cmux.swift`
- 用 ad-hoc `codesign` 给生成的 `.app` 签名

## 使用方式

1. 先自行构建 app，或者下载预编译版本
2. 把 `go2cmux.app` 拖到 Finder 工具栏
3. 在 Finder 中进入任意目录
4. 点击工具栏按钮

预期行为：

- 如果 `cmux` 已经在运行，`go2cmux` 会在现有 `cmux` 中新增一个 workspace
- 如果 `cmux` 还没运行，`go2cmux` 会先启动它，再打开当前目录

## 项目结构

- `go2cmux.swift`：app 主逻辑
- `Resources/Info.plist`：app bundle 元数据
- `scripts/build.sh`：本地构建脚本

## 已知限制

- 这是一个仅支持 macOS 的项目
- 它依赖本地已经安装 `cmux`
- 当前一次只处理一个 Finder 文件夹
- `build/` 里的 `.app` 是构建产物，不纳入 git 跟踪

## 许可证

本项目采用 MIT License。详情请见 `LICENSE` 文件。
