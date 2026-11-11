# Nous Translator

macOS 菜单栏划词翻译应用 · Selection translation for macOS

选中文字，点击翻译入口，在浮窗中查看译文。默认使用本机模型，也可以分别为翻译和对话选择在线服务。

[下载安装包](https://github.com/UndefinedWork/nous-translator/releases) · [本版更新说明](docs/releases/0.6.0-beta.1.md) · [问题反馈](https://github.com/UndefinedWork/nous-translator/issues)

## 下载与安装

当前版本为 **0.6.0-beta.1 预览版（build 7）**。

| 项目 | 要求与验证范围 |
| --- | --- |
| Mac | Apple Silicon（arm64）；不提供 Intel 版本。 |
| 系统 | 应用和本地运行器均以 macOS 14.0 为最低编译目标；目前仅在 macOS 27.3 实机验证，其他版本尚未实机验证。 |
| 本地模型 | 首次下载约 1.3 GB，需要能够访问 Hugging Face 及其下载服务的网络。权重不包含在安装包中。 |
| 签名 | 当前是 ad-hoc 签名预览版，尚无 Developer ID 签名，也未通过 Apple 公证。 |

1. 在 [GitHub Releases](https://github.com/UndefinedWork/nous-translator/releases) 下载 `Nous-Translator-0.6.0-beta.1-macOS-arm64.dmg`。
2. 打开 DMG，将 **Nous Translator.app** 拖入 **Applications（应用程序）**。
3. 从“应用程序”打开 Nous Translator。它在屏幕顶部菜单栏显示翻译图标，不常驻 Dock。

如果 macOS 因开发者无法验证或应用未公证而阻止首次打开，请先确认文件来自上述官方 Release。尝试打开后，进入 **系统设置 → 隐私与安全性 → 仍要打开（Open Anyway）**，按提示确认。步骤见 [Apple 官方说明](https://support.apple.com/en-us/102445)。受管理的 Mac 可能不允许此操作；不要关闭 Gatekeeper 或通过终端移除隔离属性来绕过系统检查。

## 第一次使用

缺少默认本地模型时，应用会自动打开 **Settings → Models**。

1. 在 **On This Mac** 点击 **Download**，下载 Index-Translate-2B Q4_K_M。可查看进度、取消和重试；下载完成后可离线翻译。也可以选择已有的兼容 GGUF 文件。
2. 打开 **Settings → Permissions**，前往系统的 **隐私与安全性 → 辅助功能**，由你打开 Nous Translator 的允许开关。应用不能替你授予权限。
3. 在支持的应用中选中文字，点击出现的翻译入口。默认语言对为简体中文 ↔ English；可在 General 中更换语言对、使用自动双向识别，或固定翻译方向。自动模式遇到第三种或无法识别的语言时，译向你选择的主语言 A。

也可以先复制文字，再从菜单栏选择 **Translate Clipboard**；剪贴板翻译不需要辅助功能权限。

下载失败时，请确认能访问 Hugging Face 后重试，或在 Models 中选择已下载的 GGUF。模型与应用分开保存，替换应用通常无需重新下载模型。

## 模型与对话

- **本地翻译**：默认使用 Index-Translate，在这台 Mac 上处理文字，无需 API Key。
- **在线模型**：可选 OpenAI、DeepSeek 或兼容 Chat Completions 的 Custom API。在 Models 中填写服务地址、模型 ID 和自己的 API Key，保存后分别选择用于 **Selection translation** 或 **Conversation**。Key 保存在 macOS Keychain。
- **通用对话**：需要单独配置通用模型，可以使用另一个本地 GGUF 或在线服务；专用翻译模型不会自动承担普通对话。
- **连接测试**：Test Connection 会向当前服务发送简短请求，可能产生费用。仅当选择在线服务时，相应文字及必要上下文才发送给该服务；本地失败不会自动切换到云端。

## 图片识别与语言

**Settings → Images** 独立选择图片文字识别方式：

- **Apple Vision · On This Mac**：默认选项，在本机识别文字，无需 Key；可选 Accurate / Fast。
- **OpenAI / Custom API**：填写支持图片输入的模型 ID、服务地址和自己的 Key，再点击 Save Image Recognition。图片模型与翻译、对话模型分别保存；同一提供方和地址可复用已保存的 Key。

在线识别会把缩放、重新编码后的图片发给所选服务，可能产生费用；未选择在线识别时不发送图片。识别只提取文字，不负责描述画面。**只发送图片即可返回识别文字，不需要对话模型**；同时输入问题时，识别文字会再交给选定的对话模型处理。PDF 和文本附件仍在本机提取。

**Settings → General → Translation Languages** 提供 16 种语言选项和常用语言对。支持自动双向、A → B、B → A，浮窗显示本次识别出的源语言与目标。短词和混合文字可能判断不准，可选择固定方向；实际语言能力取决于所选模型。

## 减少翻译前的等待

General 中的 **Online translation → Fast** 默认对已确认支持的 OpenAI 模型降低翻译请求的推理强度，保留你选择的模型，对话设置不变。可选 Model default 恢复服务默认行为；不自动购买优先处理档位。未知模型和自定义服务保持兼容参数。

**Prepare local translation model** 会提前加载已有的本地翻译模型，不预先发送翻译内容；模型闲置五分钟或遇到内存压力时释放。可关闭该选项以减少后台内存占用。等待界面会区分模型加载和等待输出，收到文字后立即流式显示。实际速度仍受模型、机器和网络影响。

翻译历史保存在本机，最多 500 条，可在 Settings → History 清除。完整的数据处理、附件保留和删除说明见 [隐私说明](PRIVACY.md)。

## 当前边界

划词兼容性取决于目标应用提供的选区信息。此版改进了 Nous Browser / Chromium 的选区读取、延迟重试和复制兜底；取消读取时尽量恢复原剪贴板，并保留后续新复制的内容。自动化回归和部分本机验证不代表所有浏览器、网页与应用均已完成端到端验收。

**当前不提供“粘贴网页 URL 后自动提取整页正文、翻译并总结”的功能。** 可先选择或复制网页中的文字进行翻译。在线服务和自行选择的通用模型，其可用性与回答质量还取决于各自配置。

## 更新与权限

从 Releases 下载新版，退出旧版后替换应用。预览版更新后，macOS 可能要求重新打开辅助功能允许开关。

项目提供的本机更新工具 `scripts/install-update.py` 会备份并替换已有安装、验证签名，然后仅重置 `com.nous.translator` 的辅助功能授权，重新打开应用和权限页面。允许开关仍须用户操作；重置失败会明确报错。它不会重置其他应用，也不会清除模型、历史、偏好或 Keychain。该工具面向维护者的已有本机安装，普通下载用户无需运行源码脚本。

## 源码与发布

源码仓库：[UndefinedWork/nous-translator](https://github.com/UndefinedWork/nous-translator)。构建需要 Apple Silicon Mac、提供 macOS 26 或更新 SDK 的 Xcode 命令行工具、Git、Python 3 和 CMake。本地运行器从固定版本的 llama.cpp 源码构建，静态包含所需组件，不依赖用户安装 Homebrew 运行库。

```sh
./scripts/test.sh
./scripts/build.sh
```

构建产物为 `build/Nous Translator.app`；构建不等于安装或授权。正式发布使用干净提交、独立输出目录和校验后的安装包，流程见 [发布指南](docs/RELEASING.md)。当前由维护者运行测试和发布脚本，尚未配置 GitHub Actions 自动发布。

应用代码的来源与许可范围见 [SOURCE_NOTICE.md](SOURCE_NOTICE.md)。公开源码不代表整个应用获得 MIT 或其他统一开源许可。运行器与单独下载的模型各有其许可，详见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 [完整许可文本](Resources/Licenses/)。
