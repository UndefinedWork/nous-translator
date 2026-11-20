# Mac App Store 版说明

Direct（GitHub）安装包保持完整划词翻译。商店版是同一仓库中的另一套编译：`NOUS_DISTRIBUTION=appstore`，定义 `NOUS_APP_STORE`，不编译辅助功能选区读取。

本文件不是许可，也不构成 Apple 审核结果。

已确认事实见 [app-store/ASC-STATUS.json](app-store/ASC-STATUS.json)：`com.nous.translator` 已在 App Store Connect 注册，资源 id `536KMKRF6V`。**仍无 App record。**

## 构建（在 Apple Silicon Mac 上）

布局验收：[`scripts/validate-appstore-macos.sh`](../scripts/validate-appstore-macos.sh)。  
上传用 PKG（仍不上传）：[`scripts/prepare-appstore-upload.sh`](../scripts/prepare-appstore-upload.sh)。  
云端 Linux **未执行**这两份脚本。

本地排版：

```sh
./scripts/test.sh
NOUS_DISTRIBUTION=appstore NOUS_ALLOW_ADHOC_STORE=1 \
  NOUS_APP_OUTPUT='/tmp/nous-appstore/Nous Translator.app' ./scripts/build.sh
python3 scripts/package-appstore.py '/tmp/nous-appstore/Nous Translator.app'
```

ad-hoc 包不可上传。真正上传需要本机钥匙串中的 **Apple Distribution**、**3rd Party Mac Developer Installer**，以及该 Bundle 的 Mac App Store provisioning profile：

```sh
export NOUS_CODESIGN_IDENTITY='Apple Distribution: [your team]'
export NOUS_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: [your team]'
export NOUS_PROVISIONING_PROFILE='/path/to/NousTranslator.provisionprofile'
./scripts/prepare-appstore-upload.sh
```

仓库不保存证书、描述文件或 Issuer 名称。`prepare-appstore-upload.sh` 拒绝 `NOUS_ASC_UPLOAD=1`。App record 仍缺失时，Transporter 会拒收 PKG。

## 商店版行为（源码）

- 菜单：Settings、Translate Clipboard、Translate Pasted Text…、Quit
- 系统服务：`Translate with Nous Translator`
- 仅商店二进制注册 `servicesProvider`
- 不编译辅助功能划词
- `llama-server` 在 `Contents/MacOS/`，inherit sandbox；应用含 `allow-jit`
- 用户选择的 GGUF 拷入容器 `Imported Models/`
- 商店版 Keychain 走 data-protection keychain
- 非本机 API 发送前按主机确认
- 随包 `PRIVACY.md`、`PrivacyInfo.xcprivacy`（含 UserDefaults `CA92.1`）

Direct 默认不变：`./scripts/build.sh` 把运行器放在 `Contents/Resources/Runtime/`，并保留划词。

## 提交前仍阻塞的事项

1. **Pico 许可：声明缺失，不是已证明无权利。** 在书面授权前不应把商店版当可上架成品。本仓库不伪造许可。
2. **App record 仍不存在。** Bundle 已注册（`536KMKRF6V`）。创建 App record、SKU、截图由账号持有人在 ASC 完成。
3. 公开隐私政策 **URL 未写入仓库**，不编造。
4. 出口合规未作答；Info.plist **不** 设置 `ITSAppUsesNonExemptEncryption`。
5. 本环境未做：沙盒实机、Metal、Apple Distribution、`productbuild`、Services 实机。当前账号无本仓库可用 Mac pool；不得占用 seede3 / Exfinix 等其他项目 worker。
6. 约 1.3 GB Hugging Face 模型下载是否被 App Review 接受，只能由审核判断。

元数据占位见 [app-store/ASC-METADATA-TEMPLATE.md](app-store/ASC-METADATA-TEMPLATE.md)。本机步骤见 [app-store/MAC-VALIDATION.md](app-store/MAC-VALIDATION.md)。
