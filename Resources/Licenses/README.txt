Nous Translator — third-party notices

The local runtime is built from llama.cpp commit:
cd959bae99ff4bed22bef2604f45241c09bbb8c8
https://github.com/ggml-org/llama.cpp/tree/cd959bae99ff4bed22bef2604f45241c09bbb8c8

The accompanying license files retain the notices for:
  llama.cpp and its included ggml source: MIT
  cpp-httplib: MIT
  nlohmann/json: MIT
  xxHash: BSD-2-Clause
  SHA-1 and SHA-256 implementations: public domain notices
  rotate-bits: MIT
  stb_image: MIT / public domain alternatives, both retained
  miniaudio: public domain / MIT-0 alternatives, both retained
  sheredom/subprocess.h and base64.hpp: Unlicense
  llamafile / tinyBLAS kernels: Mozilla Foundation MIT notice
  YaRN algorithm adaptation: MIT
  ggllm.cpp tokenizer adaptation: MIT

The runtime statically includes its required components and embeds Metal
source. This build excludes Web UI, OpenSSL, OpenMP and KleidiAI.
The operating system supplies the Apple frameworks used by the application.

YaRN license source:
https://github.com/jquesnelle/yarn/blob/995db5b575e75230b3384d658f8b944c9662f775/LICENSE
ggllm.cpp license source:
https://github.com/cmp-nct/ggllm.cpp/blob/0dc65eb735f90f82143ead9dedb66e73fa25d114/LICENSE
Other runtime notices are copied from full license files or full license
comment blocks in the fixed llama.cpp commit above.

Index-Translate.txt is the Apache-2.0 license for the default, separately
downloaded Index-Translate model. Model weights are not included in this app.
https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF

The third-party licenses apply to their respective components and do not
grant a uniform license to the Nous Translator application, branding or icon.
See SOURCE_NOTICE.txt for the application code's provenance.
