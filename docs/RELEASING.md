# Nous Translator 发布指南

发布目标为 [UndefinedWork/nous-translator](https://github.com/UndefinedWork/nous-translator)。当前流程由维护者在 Mac 上运行测试、构建和发布脚本；尚未配置 GitHub Actions。如需接入自动发布，应另行配置具备所需权限的工作流与发布凭证。

## 版本与准备

[version.json](../version.json) 是版本信息来源。当前值为：

| 字段 | 当前值 | 用途 |
| --- | --- | --- |
| `version` | `0.5.0` | 应用显示版本。 |
| `build` | `6` | 应用构建号；新构建递增。 |
| `release` | `0.5.0-beta.1` | 产物名称及 Git 标签 `v0.5.0-beta.1`。 |
| `channel` | `preview` | 预览版以 GitHub Pre-release 发布；稳定版使用 `stable`。 |
| `minimum_macos` | `14.0` | 应用与运行器的最低编译目标，不等于所有版本已经实机验证。 |
| `architecture` | `arm64` | 当前仅 Apple Silicon。 |

需要 Apple Silicon Mac、提供 macOS 26 或更新 SDK 的 Xcode 命令行工具、Git、Python 3、CMake，以及有目标仓库写入和 Release 发布权限的 GitHub CLI 登录。首次构建运行器需要访问其上游 Git 仓库；本地模型的实测另需已下载的模型。测试脚本不会调用收费模型服务。

每个版本先完成源代码变更、版本号和 `docs/releases/<release>.md` 更新说明，再审阅并提交。提交应包含本版完整变更和新增文件；之后 `git status --porcelain` 必须没有输出。不要把模型权重、个人偏好、历史、附件、日志、签名私钥、API Key 或临时构建产物提交到仓库。

发布说明应写明签名状态、实际测试系统与尚未验证的范围。当前预览版仅在 macOS 27.3 实机验证，不能因为编译目标为 14.0 就宣称所有 macOS 14 及以上版本均已验收，也不能把划词回归测试描述成所有浏览器的端到端验收。

## 预览版发布顺序

以下命令在仓库根目录执行，适用于当前 `0.5.0-beta.1`。之后的版本需同步更新说明路径。开始前已完成版本和说明的提交，工作区应保持干净。

```sh
git status --porcelain
./scripts/test.sh
NOUS_APP_OUTPUT='/tmp/nous-release-build/Nous Translator.app' ./scripts/build.sh
python3 scripts/package-release.py '/tmp/nous-release-build/Nous Translator.app'
git push origin main
python3 scripts/publish-release.py --notes docs/releases/0.5.0-beta.1.md
```

只有上一步成功才继续下一步。测试、构建或验收发现需要修复时，先修改并提交，再重新执行测试、构建和打包，保证源码、版本信息与安装包对应同一个干净提交。

各步骤的职责：

- `scripts/test.sh`：运行语言/选区规则、浏览器延迟读取、剪贴板取消与恢复、输入框、服务商请求与流式响应、设置及首次模型下载回归。模型下载测试使用本机 HTTP 服务，不真实下载权重，也不启动真实模型。
- `scripts/build.sh`：读取版本信息，从 [固定提交](../scripts/runtime-version.env) 构建 macOS 14.0 arm64 静态运行器，再构建、签名并验证应用。默认使用 ad-hoc 签名；不复制构建机器上的 Homebrew 动态库。应用记录源提交和工作区状态。
- `scripts/package-release.py`：要求源码已提交且工作区干净，检查应用中的源提交与当前提交一致，生成拖入 Applications 的 DMG、应用 ZIP、`release.json` 和 `SHA256SUMS.txt`；重新解压 ZIP、挂载 DMG 并验证其中的应用。
- `scripts/publish-release.py --notes …`：要求远端 `main` 与本地提交完全一致，校验版本、产物清单和 SHA-256，再创建并推送版本标签。先上传到草稿 Release，确认四份附件齐全后公开；`preview` 标记为 Pre-release。

产物默认写入 `release/<release>/`。打包输出目录必须为空；重复打包可通过 `--output /tmp/<新的目录>` 指定新位置，发布时用对应的 `--assets /tmp/<新的目录>`。不要混用不同构建的附件。发布脚本不会自动覆盖已有同名 Release；修复公开版本应使用新版本号和新标签。

## 稳定版：签名、公证后再打包

稳定版需要有效的 **Developer ID Application** 证书及 Apple 公证。先在 `version.json` 设置新的稳定版本、构建号和 `channel: stable`，更新说明并提交干净，再运行测试。

为构建设置并导出 `NOUS_CODESIGN_IDENTITY`，值为本机钥匙串中的实际 Developer ID Application 身份。构建脚本会为应用和运行器启用 Hardened Runtime 与时间戳。`build.sh` 内的 `verify-release.py --build-only` 允许在公证前验证构建，但稳定版仍必须具有 Developer ID 签名。

下面是独立公证步骤的示例。`NOUS_CODESIGN_IDENTITY` 和 `NOUS_NOTARY_PROFILE` 应事先配置为实际签名身份及已有的 notarytool Keychain profile；凭证不写入仓库。

```sh
NOUS_APP_OUTPUT='/tmp/nous-release-build/Nous Translator.app' ./scripts/build.sh
ditto -c -k --keepParent '/tmp/nous-release-build/Nous Translator.app' /tmp/nous-release-build/notarization.zip
xcrun notarytool submit /tmp/nous-release-build/notarization.zip --keychain-profile "$NOUS_NOTARY_PROFILE" --wait
xcrun stapler staple '/tmp/nous-release-build/Nous Translator.app'
python3 scripts/verify-release.py --require-notarized '/tmp/nous-release-build/Nous Translator.app'
python3 scripts/package-release.py '/tmp/nous-release-build/Nous Translator.app'
```

先确认 notarytool 返回 **Accepted** 并检查公证日志，再执行 stapler 和后续命令。上面的公证 ZIP 只用于提交给 Apple；最终下载包由打包脚本从已附加公证票据的应用重新生成。不能用 `--build-only` 代替最终公证验证。公证通过后若重新构建或修改应用，应重新签名、公证和打包。流程依据 [Apple 公证文档](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

打包完成后再推送对应 `main`，并使用新版本的 `--notes` 文件发布。当前 `0.5.0-beta.1` 尚未完成 Developer ID 签名或 Apple 公证，不能标为已公证稳定版。

## 安装验收与真实模型检查

打包验证只验证产物结构、签名、架构、系统目标、依赖和许可文件，不能替代首次安装体验。发布前应从最终 DMG 安装，在目标机器核对菜单栏入口、Models 下载及取消/重试、用户授予辅助功能后的划词、剪贴板翻译和实际模型结果。把已测应用、系统版本以及未测项写入版本说明。

`./scripts/test.sh` 不启动真实模型。真实推理应另行使用已下载的本地模型验证中文到英文、英文到中文，并确认本次输出。若使用应用的 `--smoke-test`，它会写固定的 `/tmp/nous-smoke-result.txt` 或 `/tmp/nous-smoke-error.txt`；每次运行前须先清理这两份上一轮测试输出，等待本次进程结束，再读取新文件，避免将旧结果误认为本轮成功。当前版本的本地运行器已在独立端口完成中英双向真实推理检查。

预览版首次打开按 [Apple 官方步骤](https://support.apple.com/en-us/102445)，在确认来源可信后使用“系统设置 → 隐私与安全性 → 仍要打开”。不要要求用户关闭 Gatekeeper 或使用终端移除隔离属性。

维护者替换已有的 `~/Applications/Nous Translator.app` 时，使用本项目的安装工具：

```sh
python3 scripts/install-update.py '/tmp/nous-release-build/Nous Translator.app'
```

该工具会备份旧应用、替换并验证签名，仅重置 `com.nous.translator` 的 Accessibility 授权，然后重新启动并打开权限页面。系统允许开关必须由用户操作；重置失败必须报告，不能声称已经自动授权。不得使用全局授权重置，也不得清除其他应用权限、模型、历史、偏好或钥匙串。此工具针对维护者的已有安装位置；公开 DMG 的用户安装路径为 `/Applications`。

## 随包说明

保留 [隐私说明](../PRIVACY.md)、[源码来源与许可范围](../SOURCE_NOTICE.md)、[第三方声明](../THIRD_PARTY_NOTICES.md) 和 [完整许可文本](../Resources/Licenses/)。应用公开源码未附统一 MIT 许可；第三方组件的许可仅适用于各自组件。更新运行器版本或构建选项时，需同步核对实际随包组件和声明。
