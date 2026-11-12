# Apple Silicon Mac 验收与商店产物（未在本环境执行）

本页给本机维护者（含 apple connect 操作者）一份可独立执行的清单。云端 Linux 环境**没有**运行这些步骤，也**没有**上传、公证或提交。

不要把仓库克隆到其他用户的机器上执行；在你自己的 Apple Silicon Mac 上，从你已有的 `UndefinedWork/nous-translator` 检出运行。

脚本入口：仓库根目录的 [`scripts/validate-appstore-macos.sh`](../../scripts/validate-appstore-macos.sh)。

## 前置

- Apple Silicon Mac（`uname -m` = `arm64`）
- 带 macOS 14+ SDK 的 Xcode 命令行工具、Python 3、CMake、Git
- 本机已检出本 PR 分支，工作区按你的发布规范处理
- **不要**使用不属于本仓库/本账号的 CI worker
- 上传用身份只存在于本机钥匙串：`Apple Distribution` 与 `3rd Party Mac Developer Installer`。仓库不保存证书名

## 一键脚本

```sh
cd /path/to/nous-translator
./scripts/validate-appstore-macos.sh
```

无 Distribution 身份时，脚本会用 `NOUS_ALLOW_ADHOC_STORE=1` 做商店**布局**包。ad-hoc 包不可上传。

有身份时：

```sh
export NOUS_CODESIGN_IDENTITY='Apple Distribution: [your team]'
export NOUS_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: [your team]'
./scripts/validate-appstore-macos.sh
```

默认产物路径：

| 产物 | 路径 |
| --- | --- |
| Direct `.app` | `/tmp/nous-direct-validate/Nous Translator.app` |
| Store `.app` | `/tmp/nous-appstore-validate/Nous Translator.app` |
| 商店 payload 目录 | `/tmp/nous-appstore-payload/` |

脚本会运行 `./scripts/test.sh`、两种 `build.sh`、`verify-release.py --build-only`、`package-appstore.py`。它**不会**调用 Transporter、`altool`、`notarytool submit`、ASC API。

## 脚本无法代替的手工项

- Direct：菜单仍有 Enable Selection Translation；授权后 TextEdit 划词仍可用
- Direct：Translate Clipboard 与 Translate Pasted Text… 仍可用
- Store：无 Enable Selection Translation；不调用 `AXIsProcessTrusted`
- Store：剪贴板、粘贴窗口、服务菜单「Translate with Nous Translator」
- Store：若服务被隐藏，在 系统设置 → 键盘 → 键盘快捷键 → 服务 中打开
- Store：用户选择的 GGUF 复制到容器内 `Imported Models/`，`Contents/MacOS/llama-server` 能加载
- Store：导入时磁盘不足时出现磁盘空间错误，且不留下 `.copying` 残留
- 隐私：首次 OpenAI / DeepSeek / Custom / 在线识图 / Test Connection 弹出主机确认；取消则不发送；Settings → Privacy 可撤销
- 本机 Custom API（`127.0.0.1` / `localhost` / `::1`）不弹确认；Hugging Face 权重下载不是该确认
- 两种版本的 Index-Translate 都能完成本地推理（商店版 helper 为 sandbox inherit）
- Pico 基准提交 `450fa2bc` 仍无 LICENSE 文件——这是**声明缺失**，不是“已证明无权利”，也不得在 ASC 填写虚构许可
- 公开隐私政策 URL 与出口合规答案仍不在仓库中，须由账号持有人另行准备

## 给 App Store Connect 的构建产物（仍须本机）

1. 在本机用 **Apple Distribution** 构建商店版（不要用 ad-hoc）：

```sh
NOUS_DISTRIBUTION=appstore \
NOUS_CODESIGN_IDENTITY='Apple Distribution: [your team]' \
NOUS_APP_OUTPUT='/tmp/nous-appstore/Nous Translator.app' \
  ./scripts/build.sh
```

2. 核对 Info.plist：`CFBundleIdentifier` = `com.nous.translator`，`NousDistribution` = `appstore`，存在 `NSServices` / `translateService`，存在 `PrivacyInfo.xcprivacy`，`llama-server` 仅在 `Contents/MacOS/`，helper 签名 Identifier = `com.nous.translator.llama-server`。

3. 打包（脚本仍不上传）：

```sh
NOUS_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: [your team]' \
  python3 scripts/package-appstore.py '/tmp/nous-appstore/Nous Translator.app' \
  --output /tmp/nous-appstore-payload
```

得到 `Nous Translator.app` 与（若提供 installer 身份）`Nous-Translator-*-appstore.pkg`，以及 `SUBMISSION-NOTES.txt`。

4. 由账号持有人在本机用 Transporter 或 Apple 文档中的上传方式提交 **PKG**。本仓库与云端环境都不执行该步。

5. ASC 元数据占位见 [ASC-METADATA-TEMPLATE.md](ASC-METADATA-TEMPLATE.md)。版权人、隐私 URL、出口合规均不得从本文件抄未替换的方括号占位符。

## 硬阻塞（与脚本是否变绿无关）

1. 继承自 Pico 的应用代码：cited commit 根目录看不到 LICENSE/COPYING。公开源码不授予统一开源许可。在权利人书面授权之前，不应把商店版当作可上架成品。
2. 本环境未在目标团队下确认 `com.nous.translator` 可用性，未创建 ASC 应用记录。
3. 无 Developer ID / Apple Distribution / 公证 / 沙盒实机 / Metal 结论可从 Linux 代称。
