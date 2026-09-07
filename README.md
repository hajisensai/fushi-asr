# fushi-asr

多语言语音识别生成字幕。**纯 Dart 核心 + 可插拔 ONNX 后端**，跑在服务端，用 CLI 或网页界面调用。

从 [Hibiki / Fushi](https://github.com/hajisensai/Fushi) 抽出为独立仓库（`hajisensai/fushi-asr`），
Hibiki 反过来引用它。命令行可执行文件仍叫 `asr`。

## 能做什么

- **17 种内置语言**：日 / 英 / 中 / 粤 / 韩 / 俄 / 越 / 泰走各自的 zipformer RNN-T；
  德 / 西 / 法 / 意 / 荷 / 葡 / 土 / 印尼 / 阿拉伯走 Meta Omnilingual ASR 1B CTC。
- **自带模型**：内置清单只是默认值。写一份 JSON 就能接自己的 zipformer / CTC 导出，
  包括内置 17 种以外的语言（`asr models export-manifest` 导个模板出来改）。
- **三种输出**：SRT / WebVTT / JSON。
- **三种用法**：命令行、HTTP API、服务端自带的网页界面。
- **有声书对齐**（`asr_align`）：把字幕 cue 与 EPUB 正文逐句对上，用锚点回填捞回漏配的段，
  再用逐 token 发射时间按正文句界重切——「一条 cue 盖了好几句」实测 18 → 0。

## 快速开始

```bash
dart pub get

# 下模型（英语 int8 约 67 MB）
dart run packages/asr_cli/bin/asr.dart models pull -l en

# 转录，字幕写 stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en 讲座.mp3 > 讲座.srt

# 或者起服务端，浏览器打开 http://127.0.0.1:8642 拖文件进去
dart run packages/asr_cli/bin/asr.dart serve
```

CLI 也可以只当客户端，把活交给远端的服务端：

```bash
asr transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### 前置条件

| 依赖 | 说明 |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib`（1.22+）。查找顺序：`ASR_ONNXRUNTIME_LIB` 环境变量 → 可执行文件同级目录 → 系统搜索路径。Windows 上还需要 Microsoft Visual C++ Redistributable。 |
| **ffmpeg** | 用来把任意音视频解成 16 kHz 单声道 PCM。查找顺序：`ASR_FFMPEG` → 可执行文件同级 → PATH。`ffprobe` 可选（缺了只是探不出总时长，进度百分比会不准）。 |

其它环境变量：`ASR_DATA_DIR`（模型与任务目录的根）、`ASR_MODELS_MANIFEST`（自带模型清单）。

## 自带模型

```bash
asr models export-manifest -o models.json   # 导出内置清单当模板
# 改完之后
asr --models models.json transcribe -l hi 印地语.mp3
```

清单按 `id` 与内置表合并，用户的包排在前面——同 id 覆盖内置，同语言优先用你的。
最小的一个包只需要 `id` / `languages` / `files`：

```json
{"packs": [{
  "id": "my-hindi-zipformer",
  "languages": ["hi"],
  "files": [
    {"fileName": "encoder.onnx", "url": "https://…", "expectedBytes": 70000000, "role": "encoderInt8"},
    {"fileName": "decoder.onnx", "url": "https://…", "expectedBytes": 700000,   "role": "decoderInt8"},
    {"fileName": "joiner.onnx",  "url": "https://…", "expectedBytes": 400000,   "role": "joinerInt8"},
    {"fileName": "tokens.txt",   "url": "https://…", "expectedBytes": 50000,    "role": "tokens"},
    {"fileName": "silero_vad.onnx", "url": "https://…", "expectedBytes": 643854, "role": "vad"}
  ]
}]}
```

其余字段有缺省（`architecture: transducer`、`indexType: int64`、`decoderContextSize: 2`、
`blankToken: <blk>`）。**CTC 包必须显式写 `blankToken`**——它没有共识默认值，猜错就是整篇乱码。

## HTTP API

| 接口 | 说明 |
|---|---|
| `GET /` | 网页界面（单文件、零外部资源，内网离线可用） |
| `GET /v1/health` | 探活，不需要令牌 |
| `GET /v1/models` | 认得哪些语言与模型包 |
| `POST /v1/transcribe?language=ja&format=srt` | **请求体就是音频字节**（不做 multipart）。响应是流式 NDJSON，一行一个进度事件，最后一行是 `result` 或 `error` |

设了 `--token` 时请求要带 `Authorization: Bearer <token>`。

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

**判成功的依据是「有没有收到 `result` 行」，不是 HTTP 状态码**：响应一旦开始流式写就
改不了状态码，失败只能作为最后一行送回来。

## 包结构

| 包 | 内容 | 依赖 |
|---|---|---|
| `asr_core` | 纯 Dart 转录核心：VAD 分段、fbank、RNN-T 贪心 Loop 图 / CTC 解码、攒批分桶、fp16 图转换、模型清单与下载、SRT 产出。**零 Flutter、零 dart:ffi、不自带 ONNX 后端** | `meta` `path` `crypto` |
| `asr_onnx_ffi` | ONNX Runtime 的 dart:ffi 后端（CPU / DirectML / CUDA） | `asr_core` `ffi` |
| `asr_align` | EPUB / 文本 ↔ 音频对齐：句级 Dice 匹配（含 ruby 读音轨）、锚点间隙回填、按正文句界重切 cue | `asr_core` |
| `asr` | 门面：一步到位的 `TranscribeRunner` + 字幕格式 | 上面两个 |
| `asr_server` | HTTP 服务端与客户端 + 网页界面 | `asr` |
| `asr_cli` | `asr` 命令行 | `asr` `asr_server` `args` |

分层的意义在于**算法层只依赖一个窄接口**（`OnnxSessionFactory.createSession`）。
Flutter 宿主注入自己的插件后端，服务端注入 FFI 后端，同一套算法两边跑。

## 开发

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 条
cd packages/asr_onnx_ffi && dart test    # 15 条，要真 onnxruntime（没有就整组 skip）
cd packages/asr_align && dart test       # 15 条
cd packages/asr && dart test             # 10 条
cd packages/asr_server && dart test      # 10 条
```

重新生成 ORT FFI 绑定（改 ORT 版本时才需要，产物已入库，普通使用者不必装 LLVM）：

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

诊断：`ASR_TRACE_SHUTDOWN=1` 会把转录收尾的每一步写到 stderr（关会话 → 关 PCM 桥 →
退出消息 → 服务端写响应），排查「跑完了却卡住」时用。

实施计划与设计取舍见 [docs/PLAN.md](docs/PLAN.md)。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。`third_party/onnxruntime/` 下的头文件来自
ONNX Runtime（MIT），保留其原始许可。
