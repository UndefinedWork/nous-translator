# App Store Connect 元数据模板

不要把方括号占位符当成真实 URL、法律主体或已批准的问卷答案。已核对的事实写在 [ASC-STATUS.json](ASC-STATUS.json)。

## 应用记录

| 字段 | 值 | 说明 |
| --- | --- | --- |
| Name | Nous Translator | 与 `CFBundleDisplayName` 一致 |
| Bundle ID | `com.nous.translator` | **已注册** |
| ASC bundle id | `536KMKRF6V` | Connect 资源 id；不要把它写进 entitlements 当 Team ID，除非描述文件里的 App ID prefix 就是它 |
| App record | 无 | 账号持有人仍需创建 Mac 应用记录 |
| SKU | `[SKU]` | 由账号持有人自定 |
| Primary language | `[LANGUAGE]` | |
| Category | Productivity | `LSApplicationCategoryType` = `public.app-category.productivity` |
| Copyright | `[COPYRIGHT_HOLDER]` | 仓库未记录权利人；Pico 声明缺失仍阻塞上架 |
| Privacy policy URL | 无 | **仓库故意不写 URL，不编造** |
| Support URL | https://github.com/UndefinedWork/nous-translator/issues | 本仓库已有的问题反馈入口，不是占位符 |
| Age rating | `[AGE_RATING]` | 按问卷回答 |

## 隐私营养标签（需按当时行为填写）

- 应用本身无分析 SDK、无广告、无账号系统。
- 本地翻译与 Apple Vision 不把用户文本或图片发到开发者服务器。
- 用户选择 OpenAI / DeepSeek / Custom API / 在线识图后，请求中的文本或重编码图片会发到该主机。是否勾选 User Content，对照各服务方政策，不能在仓库里代填。
- Hugging Face 模型下载会暴露 IP 和文件路径；应用不把译文附在该请求上。
- Tracking：`PrivacyInfo.xcprivacy` 中 `NSPrivacyTracking` 为 false。
- Required Reason API：UserDefaults `CA92.1`（同一应用内偏好）。

## 审核备注草稿（上传前按实机结果改写）

```
This Mac App Store build does not use Accessibility APIs and does not read other apps’ selection.
Translate Clipboard, Translate Pasted Text, and the “Translate with Nous Translator” service are the supported ways to provide text.
Local translation uses a bundled llama-server bound to 127.0.0.1. The default ~1.3 GB model is an optional user download from Hugging Face; the app remains usable with clipboard text and a user-configured HTTPS API.
We do not automatically fall back from a local model to a cloud API.
API keys are stored in the data-protection keychain. The helper inherits the app sandbox.
```

不要在审核备注中粘贴 API Key。
