# Nous Translator

macOS 菜单栏划词翻译应用 · Selection translation for macOS

选中文字，点击翻译入口，在浮窗中查看译文。默认使用本机模型，也可以分别为翻译和对话选择在线服务。

[下载安装包](https://github.com/UndefinedWork/nous-translator/releases) · [本版更新说明](docs/releases/0.7.0-beta.1.md) · [问题反馈](https://github.com/UndefinedWork/nous-translator/issues)

## 下载与安装

当前版本为 **0.7.0-beta.1 预览版（build 11）**。

| 项目 | 要求与验证范围 |
| --- | --- |
| Mac | Apple Silicon（arm64）；不提供 Intel 版本。 |
| 系统 | 应用和本地运行器均以 macOS 14.0 为最低编译目标；目前仅在 macOS 27.3 实机验证，其他版本尚未实机验证。 |
| 本地模型 | 首次下载约 1.3 GB，支持官方 Hugging Face、HF-Mirror 或自定义 HTTPS 镜像（含断点续传与 SHA-256 校验）。权重不包含在安装包中。 |
| 签名 | 当前是 ad-hoc 签名预览版，尚无 Developer ID 签名，也未通过 Apple 公证。 |

1. 在 [GitHub Releases](https://github.com/UndefinedWork/nous-translator/releases) 下载 `Nous-Translator-0.7.0-beta.1-macOS-arm64.dmg`。
2. 打开 DMG，将 **Nous Translator.app** 拖入 **Applications（应用程序）**。
3. 从“应用程序”打开 Nous Translator。它在屏幕顶部菜单栏显示翻译图标，不常驻 Dock。

如果 macOS 因开发者无法验证或应用未公证而阻止首次打开，请先确认文件来自上述官方 Release。尝试打开后，进入 **系统设置 → 隐私与安全性 → 仍要打开（Open Anyway）**，按提示确认。步骤见 [Apple 官方说明](https://support.apple.com/en-us/102445)。受管理的 Mac 可能不允许此操作；不要关闭 Gatekeeper 或通过终端移除隔离属性来绕过系统检查。

## 第一次使用

缺少默认本地模型时，应用会自动打开 **Settings → Models**。

1. 在 **On This Mac** 选择下载源（支持官方 Hugging Face、HF-Mirror 或自定义 HTTPS 镜像），点击 **Download** 下载 Index-Translate-2B Q4_K_M。支持进度查看、取消后断点续传（Resume）以及 SHA-256 校验；下载完成后可离线翻译。也可以选择已有的兼容 GGUF 文件。
2. 打开 **Settings → Permissions → Open System Settings…**。在较早的 macOS 上，前往「隐私与安全性 → 辅助功能」打开 Nous Translator。macOS 27.3 的系统页面名为 **System & App Protection Override**。如果列表没有 Nous Translator，点 **＋** 选择已安装的 App，然后点 **Choose Apps**，选择你要划词的应用，例如 Nous Browser，并按系统提示确认。[Apple 授权说明](https://support.apple.com/en-us/149699)
3. 在支持的应用中选中文字，点击出现的翻译入口。默认语言对为简体中文 ↔ English；可在 General 中更换语言对、使用自动双向识别，或固定翻译方向。浮窗顶部支持一键切换目标语言或反转方向，支持自适应紧凑高度与拖动边角缩放、原生语音朗读、停止生成、重译（`⌘R`）和复制译文（`⌘⇧C` / `⌘C`）。

也可以通过菜单栏或可自定义全局快捷键（默认 `⌃⌥T` 翻译剪贴板、`⌃⌥N` 快捷输入翻译、`⌃⌥S` 截图区域 OCR 识别并翻译）随时调用；剪贴板翻译和全局快捷键不需要辅助功能权限。

下载失败时，可切换镜像源后点击继续下载（Resume），或在 Models 中选择已下载的 GGUF。模型与应用分开保存，替换应用通常无需重新下载模型。

## 模型与对话

- **本地翻译**：默认使用 Index-Translate，每次启动动态分配本地回环端口并在本机处理文字，无需 API Key。
- **在线模型**：可选 OpenAI、DeepSeek 或兼容 Chat Completions 的 Custom API。在 Models 中填写服务地址、模型 ID 和自己的 API Key（界面直接显示 Keychain 保存状态与未保存提醒），保存后分别选择用于 **Selection translation** 或 **Conversation**。在线翻译使用结构化提示词与来源应用语域上下文，错误响应透出经脱敏的服务端诊断信息。
- **通用对话**：需要单独配置通用模型，可以使用另一个本地 GGUF（采用独立对话上下文与温度参数）或在线服务；专用翻译模型不会自动承担普通对话。
- **连接测试**：Models 与 Images 页均提供 Test Connection，向当前服务发送简短请求（Images 页发送微型测试图），可能产生费用。仅当选择在线服务时，相应文字或图片才发送给该服务；本地失败不会自动切换到云端。

## 图片识别与语言

**Settings → Images** 独立选择图片文字识别方式，同时服务于附件图片识别与**截图区域 OCR 翻译**：

- **Apple Vision · On This Mac**：默认选项，在本机识别文字，无需 Key；可选 Accurate / Fast。首次或系统缓存未命中时，macOS 准备识别模型可能需要约 20 秒或更久，超过 3 秒时界面会提示准备状态；处理在后台进行，后续通常会更快。
- **OpenAI / Custom API**：填写支持图片输入的模型 ID、服务地址和自己的 Key，保存后可直接点击 **Test Connection** 验证图片输入能力。图片模型与翻译、对话模型分别保存；同一提供方和地址可复用已保存的 Key。

在线识别会把缩放、重新编码后的图片发给所选服务，可能产生费用；未选择在线识别时不发送图片。识别只提取文字，不负责描述画面。**只发送图片即可返回识别文字，不需要对话模型**；同时输入问题时，识别文字会再交给选定的对话模型处理。PDF 和文本附件仍在本机提取。

**Settings → General** 提供 16 种语言选项和常用语言对（含短英文词识别优化）、中/英界面语言切换以及全局快捷键录制。翻译历史保存在本机，最多 500 条，支持在 **Settings → History** 中搜索、单条删除、复制原文以及重新在浮窗打开继续追问。关闭浮窗会自动取消未完成的后台任务并清理临时附件副本。完整的数据处理说明见 [隐私说明](PRIVACY.md)。

## 减少翻译前的等待

General 中的 **Online translation → Fast** 默认对已确认支持的 OpenAI 模型降低翻译请求的推理强度，保留你选择的模型，对话设置不变。可选 Model default 恢复服务默认行为；不自动购买优先处理档位。未知模型和自定义服务保持兼容参数。

**Prepare local translation model** 会提前加载已有的本地翻译模型，不预先发送翻译内容；模型闲置五分钟或遇到内存压力时释放。可关闭该选项以减少后台内存占用。等待界面会区分模型加载和等待输出，收到文字后立即流式显示。实际速度仍受模型、机器和网络影响。

翻译历史保存在本机，最多 500 条，可在 Settings → History 清除。完整的数据处理、附件保留和删除说明见 [隐私说明](PRIVACY.md)。

## 当前边界

划词兼容性取决于目标应用提供的选区信息。此版改进了 Nous Browser / Chromium 的选区读取、延迟重试和复制兜底；取消读取时尽量恢复原剪贴板，并保留后续新复制的内容。自动化回归和部分本机验证不代表所有浏览器、网页与应用均已完成端到端验收。

**当前不提供“粘贴网页 URL 后自动提取整页正文、翻译并总结”的功能。** 可先选择或复制网页中的文字进行翻译。在线服务和自行选择的通用模型，其可用性与回答质量还取决于各自配置。

## 更新与权限

应用内置基于 **GitHub Releases** 的更新检查与一键更新：

- **自动检测与提示**：启动后定期检查 `UndefinedWork/nous-translator` 的 GitHub Releases（可在 **Settings → General → Software Update** 开关自动检查或切换是否接收预览版）。发现新版本时，菜单栏图标会显示提示圆点并弹出轻量更新提示，菜单顶部同步出现更新入口。
- **一键下载、校验并自动重启**：点击提示或菜单项进入 **Settings → General**，可查看新版本更新说明并点击 **Download & Install Update（一键下载并更新）**。应用会从 GitHub HTTPS 下载对应发布包，核验 `SHA256SUMS.txt` / `release.json` 与 `codesign` 签名，以原子方式替换当前 `.app`（失败自动回滚）并自动重启新版。模型、历史、偏好和 Keychain 密钥均完整保留。
- **权限说明**：预览版（ad-hoc 签名）更新后由于签名指纹变化，更新器会仅重置 `com.nous.translator` 的辅助功能授权并打开系统权限页，由用户重新确认允许开关；若重置失败会在重启后明确弹窗提示。稳定版（Developer ID）满足原有签名要求时保持权限不变。

也可以从 Releases 手动下载新版，退出旧版后替换应用。面向维护者本机替换源码构建包的命令行工具 `scripts/install-update.py` 仍保留可用。

## 源码与发布

源码仓库：[UndefinedWork/nous-translator](https://github.com/UndefinedWork/nous-translator)。构建需要 Apple Silicon Mac、提供 macOS 26 或更新 SDK 的 Xcode 命令行工具、Git、Python 3 和 CMake。本地运行器从固定版本的 llama.cpp 源码构建，静态包含所需组件，不依赖用户安装 Homebrew 运行库。

```sh
./scripts/test.sh
./scripts/build.sh
```

构建产物为 `build/Nous Translator.app`；构建不等于安装或授权。正式发布使用干净提交、独立输出目录和校验后的安装包，流程见 [发布指南](docs/RELEASING.md)。当前由维护者运行测试和发布脚本，尚未配置 GitHub Actions 自动发布。

应用代码的来源与许可范围见 [SOURCE_NOTICE.md](SOURCE_NOTICE.md)。公开源码不代表整个应用获得 MIT 或其他统一开源许可。运行器与单独下载的模型各有其许可，详见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 [完整许可文本](Resources/Licenses/)。
