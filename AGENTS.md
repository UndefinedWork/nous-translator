# Nous Translator 工作约定

- 用户明确要求：每次本机安装/替换新版后，重置本应用的辅助功能授权，避免用户手动删除旧条目后再添加。
- 使用 `scripts/install-update.py`：退出旧版、备份、替换并验证签名，然后执行 `tccutil reset Accessibility com.nous.translator`，启动新版并打开系统辅助功能权限页面。
- 仅重置 `com.nous.translator` 的 Accessibility 授权，不使用全局 reset、不重置其他应用，不清除模型、历史、偏好或钥匙串。
- 系统的允许开关必须由用户操作；不能宣称已经自动授权。重置失败须明确报告。
- 官方仓库为 `UndefinedWork/nous-translator`。用户已明确授权先发布公开预览版；本次授权取代此前等待本机测试确认后才建仓/发布的约定。
- 后续功能更新须同步提交源码、版本与说明，并按 `docs/RELEASING.md` 运行测试、构建、打包验证，发布对应 GitHub Release。没有 Developer ID 与 Apple 公证时，只发布明确标注的预览版，不作为正式稳定版。
- 不提交模型权重、用户数据、运行日志、备份、API Key、签名私钥或构建产物。安装包只通过 Release 分发。
- 不覆盖已经公开的版本或标签；修复应增加版本和构建号。报告未完成的实机/在线验证，不把部署目标当作实机兼容结论。
