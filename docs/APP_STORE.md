# Mac App Store 版说明

Direct（GitHub）安装包保持完整划词翻译。商店版是同一仓库中的另一套编译：`NOUS_DISTRIBUTION=appstore`，定义 `NOUS_APP_STORE`，不编译辅助功能选区读取。

本文件不是许可，也不构成 Apple 审核结果。

## 构建（在 Apple Silicon Mac 上）

完整本机清单与产物路径见 [app-store/MAC-VALIDATION.md](app-store/MAC-VALIDATION.md)。入口脚本是 `scripts/validate-appstore-macos.sh`（须在 arm64 macOS 上运行；云端 Linux **未执行**）。

```sh
./scripts/test.sh
NOUS_DISTRIBUTION=appstore NOUS_ALLOW_ADHOC_STORE=1 \
  NOUS_APP_OUTPUT='/tmp/nous-appstore/Nous Translator.app' ./scripts/build.sh
python3 scripts/package-appstore.py '/tmp/nous-appstore/Nous Translator.app'
```

本地排版检查可以用 ad-hoc 签名（`NOUS_ALLOW_ADHOC_STORE=1`）。真正上传需要本机钥匙串中的 **Apple Distribution** 身份，通过 `NOUS_CODESIGN_IDENTITY` 传入；安装包签名使用 `NOUS_INSTALLER_IDENTITY`。仓库不保存证书、描述文件或 Issuer 名称。

`scripts/package-appstore.py` **不会** 在 App Store Connect 建应用、注册 Bundle ID、上传或提交。那些步骤由维护者在 Apple 的网站上完成。

## 商店版行为（源码）

- 菜单：Settings、Translate Clipboard、Translate Pasted Text…、Quit
- 系统服务：`Translate with Nous Translator`（`NSMessage` = `translateService`，selector 接受可选 `userData`/`error`）
- 仅商店二进制调用 `NSApp.servicesProvider`；Direct 的 Info.plist 不声明 `NSServices`
- 不启动全局选区监视，不调用 `AXIsProcessTrusted` / `AXUIElement`
- Info.plist **不**设置 `NSPrincipalClass`（SwiftUI `@main` 生成入口；写成 `NSApplication` 会跳过 `NousTranslatorApp`）
- `llama-server` 安装在 `Contents/MacOS/`，以 Identifier `com.nous.translator.llama-server` 签名，entitlements 仅为 `app-sandbox` + `inherit`
- 用户选择的 GGUF 先拷到暂存名再移入 `Imported Models/`；磁盘失败会删除不完整文件
- 向非本机 API 主机发送前按主机确认（翻译、对话、Test Connection、在线识图，含测试注入的 transport）；可在 Settings → Privacy 撤销
- Hugging Face 模型权重下载不是上述确认
- 随包 `PRIVACY.md`、`PrivacyInfo.xcprivacy`、第三方许可文本

Direct 构建默认路径不变：`./scripts/build.sh` 仍把运行器放在 `Contents/Resources/Runtime/`，并保留划词。粘贴窗口在 Direct 上不显示商店版专用说明。

## 提交前仍阻塞的事项

1. **继承代码许可：声明缺失，不是“已证明无权利”。** [SOURCE_NOTICE.md](../SOURCE_NOTICE.md) 写明 Pico 基准提交 [`450fa2bc`](https://github.com/cellier/Pico/tree/450fa2bc1dbf5651da513c2a2efd4c234f1dc7e2) 未声明开源许可。远程目录列举在该提交根路径看不到 `LICENSE`/`COPYING`。这不能当成法律上已确认没有权利，也不得据此伪造许可。在权利人书面授权之前，**不应把商店版当作可上架成品**。
2. App Store Connect 中尚无本应用记录，也未在本环境注册 Bundle ID。`com.nous.translator` 是否可在目标团队下使用，需在开发者账号中确认。不要复用其他产品的签名、隐私问卷或 App 记录。
3. 公开隐私政策 **URL 未写入仓库**。Settings → Privacy 显示随包 `PRIVACY.md`。提交元数据需要另备可访问的 URL。
4. 导出合规问卷未作答；Info.plist **不** 设置 `ITSAppUsesNonExemptEncryption`。
5. 本环境未做：沙盒实机、Metal 推理、Apple Distribution 签名、`productbuild`、Transporter 上传、系统服务菜单实机。
6. 约 1.3 GB 的 Hugging Face 模型下载仍是用户可选路径；审核条款 2.4.5(iv) / 2.5.2 是否接受，只能由 App Review 判断。
7. Hugging Face 托管条款、Index-Translate 与 Qwen 基础模型是否还另有限制，见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)；此处不作法律结论。

元数据占位见 [app-store/ASC-METADATA-TEMPLATE.md](app-store/ASC-METADATA-TEMPLATE.md)。
