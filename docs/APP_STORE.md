# Mac App Store 版说明

Direct（GitHub）安装包保持完整划词翻译。商店版是同一仓库中的另一套编译：`NOUS_DISTRIBUTION=appstore`，定义 `NOUS_APP_STORE`，不编译辅助功能选区读取。

本文件不是许可，也不构成 Apple 审核结果。

## 构建（在 Apple Silicon Mac 上）

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
- 系统服务：`Translate with Nous Translator`（`NSMessage` = `translateService`）
- 不启动全局选区监视，不调用 `AXIsProcessTrusted` / `AXUIElement`
- `llama-server` 安装在 `Contents/MacOS/`，entitlements 仅为 `app-sandbox` + `inherit`
- 用户选择的 GGUF 复制进应用数据目录
- 向非本机 API 主机发送前按主机确认，可在 Settings → Privacy 撤销
- 随包 `PRIVACY.md`、`PrivacyInfo.xcprivacy`、第三方许可文本

Direct 构建默认路径不变：`./scripts/build.sh` 仍把运行器放在 `Contents/Resources/Runtime/`，并保留划词。

## 提交前仍阻塞的事项

1. **继承代码许可未解决。** [SOURCE_NOTICE.md](../SOURCE_NOTICE.md) 写明 Pico 基准提交未声明开源许可，公开源码不授予统一 MIT/Apache 许可。在权利人书面授权之前，**不应把商店版当作可上架成品**。本仓库不会伪造该许可。
2. App Store Connect 中尚无本应用记录，也未在本环境注册 Bundle ID。`com.nous.translator` 是否可在目标团队下使用，需在开发者账号中确认。不要复用其他产品的签名、隐私问卷或 App 记录。
3. 公开隐私政策 **URL 未写入仓库**。Settings → Privacy 显示随包 `PRIVACY.md`。提交元数据需要另备可访问的 URL。
4. 导出合规问卷未作答；Info.plist **不** 设置 `ITSAppUsesNonExemptEncryption`。
5. 本环境未做：沙盒实机、Metal 推理、Apple Distribution 签名、`productbuild`、Transporter 上传。
6. 约 1.3 GB 的 Hugging Face 模型下载仍是用户可选路径；审核条款 2.4.5(iv) / 2.5.2 是否接受，只能由 App Review 判断。
7. Hugging Face 托管条款、Index-Translate 与 Qwen 基础模型是否还另有限制，见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)；此处不作法律结论。

元数据占位见 [app-store/ASC-METADATA-TEMPLATE.md](app-store/ASC-METADATA-TEMPLATE.md)。
