# App Store Connect 元数据模板

不要把本文件里的方括号占位符当成真实 URL、法律主体或已批准的问卷答案。提交前由维护者替换，并与当时的应用行为核对。

## 应用记录

| 字段 | 占位 | 说明 |
| --- | --- | --- |
| Name | Nous Translator | 与 `CFBundleDisplayName` 一致 |
| Bundle ID | `com.nous.translator` | 仅当该团队尚未被占用且你决定沿用源码中的 ID |
| SKU | `[SKU]` | 由账号持有人自定 |
| Primary language | `[LANGUAGE]` | |
| Category | Productivity | 对应 `LSApplicationCategoryType` = `public.app-category.productivity` |
| Copyright | `[COPYRIGHT_HOLDER]` | 仓库未记录权利人；`SOURCE_NOTICE.md` 仍是阻塞项 |
| Privacy policy URL | `[PRIVACY_POLICY_URL]` | **仓库故意不写 URL** |
| Support URL | `[SUPPORT_URL]` | 例如 GitHub Issues，需你确认后填写 |
| Age rating | `[AGE_RATING]` | 按问卷回答 |

## 隐私营养标签（需按当时行为填写）

下列是根据当前源码需要核对的方向，不是已提交的答案：

- 应用本身无分析 SDK、无广告、无账号系统。
- 本地翻译与 Apple Vision 不把用户文本或图片发到开发者服务器。
- 用户选择 OpenAI / DeepSeek / Custom API / 在线识图后，请求中的文本或重编码图片会发到该主机。Apple 对 “Collect” 的定义见 [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)。是否因服务方保留日志而必须勾选 User Content / Other User Content，要对照各服务方政策，不能在仓库里替你勾选。
- Hugging Face 模型下载会暴露 IP 和文件路径；应用不把译文附在该请求上。
- Tracking：当前实现未使用 ATT 或广告标识。`PrivacyInfo.xcprivacy` 中 `NSPrivacyTracking` 为 false。

## 审核备注草稿（上传前改写）

```
This Mac App Store build does not use Accessibility APIs and does not read other apps’ selection.
Translate Clipboard, Translate Pasted Text, and the “Translate with Nous Translator” service are the supported ways to provide text.
Local translation uses a bundled llama-server bound to 127.0.0.1. The default ~1.3 GB model is an optional user download from Hugging Face; the app remains usable with clipboard text and a user-configured HTTPS API.
We do not automatically fall back from a local model to a cloud API.
```

不要在审核备注中粘贴 API Key。
