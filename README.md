# asr

多语言语音识别生成字幕。纯 Dart 核心 + 可插拔 ONNX 后端，跑在服务端，用 CLI 或界面调用。

从 [Hibiki/Fushi](https://github.com/hajisensai/Fushi) 抽出为独立仓库。

## 状态

早期阶段。当前进度见 [docs/PLAN.md](docs/PLAN.md)。

| 包 | 状态 |
|---|---|
| `packages/asr_core` | ✅ 纯 Dart 转录核心，零 Flutter 依赖，312 条测试通过 |
| `packages/asr_onnx_ffi` | 🚧 dart:ffi ONNX Runtime 后端 |
| `packages/asr_align` | 🚧 EPUB/文本 ↔ 音频匹配、句界重切、CTC 强制对齐 |
| `packages/asr_server` | 🚧 HTTP API + 内置界面 |
| `packages/asr_cli` | 🚧 `asr transcribe` / `asr serve` / `asr models` |

## 许可

GPL-3.0。见 [LICENSE](LICENSE)。
