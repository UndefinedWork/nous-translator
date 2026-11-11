# 第三方组件与许可

本说明区分应用代码、随安装包分发的运行组件和单独下载的模型。Nous Translator 应用代码的来源及许可范围见 [SOURCE_NOTICE.md](SOURCE_NOTICE.md)；本页列出的第三方许可不构成整个应用的统一开源许可。

## 本地运行器

本版运行器从 [llama.cpp 提交 `cd959bae99ff4bed22bef2604f45241c09bbb8c8`](https://github.com/ggml-org/llama.cpp/tree/cd959bae99ff4bed22bef2604f45241c09bbb8c8) 构建，使用该提交内的 ggml 源码。`llama-server` 静态包含所需的推理及服务代码，启用 Apple CPU、Accelerate 和内嵌 Metal 支持。许可证文本从该固定提交的原始文件或完整许可注释提取，保留原有版权、许可和免责声明。

| 组件 | 许可 | 随包完整文本 | 上游文件或说明 |
| --- | --- | --- | --- |
| llama.cpp | MIT | [llama.cpp.txt](Resources/Licenses/llama.cpp.txt) | 上游 `LICENSE` |
| ggml | MIT | [ggml.txt](Resources/Licenses/ggml.txt) | 上述 llama.cpp 提交内的 `ggml/`；保留上游项目 MIT 许可 |
| cpp-httplib | MIT | [cpp-httplib.txt](Resources/Licenses/cpp-httplib.txt) | `vendor/cpp-httplib/LICENSE`，另保留同版本头文件中的版权声明 |
| nlohmann/json 及其内嵌子组件 | MIT | [nlohmann-json.txt](Resources/Licenses/nlohmann-json.txt) | `licenses/LICENSE-jsonhpp`，另保留 `json.hpp` 内各作者的 SPDX 版权声明 |
| xxHash | BSD-2-Clause | [xxhash.txt](Resources/Licenses/xxhash.txt) | `vendor/hash/xxhash/LICENSE` |
| SHA-1 implementation | Public Domain | [sha1.txt](Resources/Licenses/sha1.txt) | `vendor/hash/sha1/sha1.c` 的原始作者及公共领域声明 |
| SHA-256 implementation | Public Domain | [sha256.txt](Resources/Licenses/sha256.txt) | `vendor/hash/sha256/LICENSE` |
| rotate-bits | MIT | [rotate-bits.txt](Resources/Licenses/rotate-bits.txt) | `vendor/hash/rotate-bits/LICENSE.md` |
| stb_image | MIT 或 Public Domain / Unlicense | [stb_image.txt](Resources/Licenses/stb_image.txt) | `vendor/stb/stb_image.h` 末尾完整双许可声明 |
| miniaudio | Public Domain / Unlicense 或 MIT-0 | [miniaudio.txt](Resources/Licenses/miniaudio.txt) | `vendor/miniaudio/miniaudio.h` 末尾完整双许可声明 |
| sheredom/subprocess.h | Unlicense | [subprocess.txt](Resources/Licenses/subprocess.txt) | `vendor/sheredom/subprocess.h` 中的完整许可声明 |
| base64.hpp | Unlicense | [base64.txt](Resources/Licenses/base64.txt) | `common/base64.hpp` 中的完整许可声明 |
| llamafile / tinyBLAS CPU kernels | MIT | [llamafile.txt](Resources/Licenses/llamafile.txt) | `ggml/src/ggml-cpu/llamafile/sgemm.cpp` 的 Mozilla Foundation 版权及许可声明 |
| YaRN algorithm adaptation | MIT | [YaRN.txt](Resources/Licenses/YaRN.txt) | CPU 与 Metal RoPE 代码保留的 Jeffrey Quesnelle、Bowen Peng 归属；完整许可取自 [YaRN `995db5b`](https://github.com/jquesnelle/yarn/blob/995db5b575e75230b3384d658f8b944c9662f775/LICENSE) |
| ggllm.cpp tokenizer adaptation | MIT | [ggllm.cpp.txt](Resources/Licenses/ggllm.cpp.txt) | `src/llama-vocab.cpp` 标注的代码来源；完整许可取自 [ggllm.cpp `0dc65eb`](https://github.com/cmp-nct/ggllm.cpp/blob/0dc65eb735f90f82143ead9dedb66e73fa25d114/LICENSE) |

本版构建关闭 Web UI、OpenSSL、OpenMP 和 KleidiAI，不随此运行器分发这些组件及 Web UI 的 JavaScript 依赖。macOS 自带的系统框架由操作系统提供，不复制到应用中。未来改变构建配置或运行器版本时，应重新核对实际分发内容及其许可，不能直接沿用本表。

## 单独下载的模型

默认翻译模型为 [IndexTeam/Index-Translate-2B-GGUF](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF) 的 `Index-Translate-2B.Q4_K_M.gguf`。官方模型说明将许可标为 **Apache-2.0**；完整文本保留在 [Index-Translate.txt](Resources/Licenses/Index-Translate.txt)。模型权重由用户单独下载，不包含在源码仓库或应用安装包中。

用户选择的其他 GGUF 模型适用该模型自己的许可，不应由本默认模型的许可推定其使用或分发范围。

## 再分发时保留

适用的完整许可文本随应用保存在 `Nous Translator.app/Contents/Resources/Licenses/`。再分发相关组件时，应保留相应版权、许可条件及免责声明；Apache-2.0 组件如果另外附带适用的 NOTICE，也应一并保留。对上游组件的修改应按其许可保留必要说明。

本表用于标识来源和随包声明，完整许可文本优先于本表的简写标签。它不代表上游作者为 Nous Translator 提供背书。
