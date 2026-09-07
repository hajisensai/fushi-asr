# `asr` 独立仓库实施计划

从 Hibiki（`hajisensai/Fushi`）PR #1262 那一套「生成字幕」抽出独立仓库，Hibiki 反过来引用它。

## 决策（已确认）

| 项 | 决定 |
|---|---|
| 仓库 | `hajisensai/fushi-asr` |
| 许可 | GPL-3.0（与 Hibiki 一致，零冲突） |
| 形态 | **只做服务端**。转录一律在服务端（本机或远程主机）跑，CLI 与界面都是调用方；**不做浏览器端 WASM 推理** |
| 范围 | ASR 转录核心 **+** 对齐层（EPUB/文本 ↔ 音频匹配、句界重切、CTC 强制对齐） |
| 额外要求 | **支持配置其他模型**：内置 17 语言清单改成数据驱动，用户可自带模型清单 |

## 为什么这套能抽出来（证据）

抽取接缝已经存在且极窄：算法层只依赖 `onnx_inference.dart` 里的

```dart
OnnxSessionFactory.createSession(modelPath, {providers, intraOpNumThreads, freeDimensionOverrides})
  -> OnnxSession.run(Map<String, OnnxTensor>) / close()
```

`fushi/lib/src/asr/` 19 个文件对 Flutter 的依赖统计：`@immutable` ×16、`@visibleForTesting` ×5、
`debugPrint` ×5、`compute()` ×3、`listEquals` ×1 —— **全是装饰性的**，换 `package:meta` +
`Isolate.run` + `package:collection` 即可。

唯一结构性 Flutter 依赖是 `asr_transcribe_isolate.dart` 的 `BackgroundIsolateBinaryMessenger` /
`RootIsolateToken`，而它存在的**唯一原因**就是 ONNX 后端是 method channel 插件（后台 isolate 要重新
挂上 binary messenger 才能发方法调用）。**FFI 后端直接消灭这个依赖。**

零依赖纯 Dart、可原样搬的资产：`asr_fbank.dart`（kaldi 兼容 fbank）、`asr_vad.dart`、
`onnx_proto.dart`（纯 Dart ONNX protobuf 读写）、`asr_greedy_graph.dart`（运行时拼贪心 Loop 图）、
`asr_fp16_graph.dart`（整图 fp32→fp16）、`asr_cue_builder.dart`、`asr_types.dart`、
`model_file_downloader.dart`。

## 仓库结构

```
asr/                                GPL-3.0，Dart pub workspace（无需 melos）
├── packages/asr_core/              纯 Dart 转录核心，零 Flutter、零 dart:ffi
├── packages/asr_onnx_ffi/          dart:ffi ORT 后端（CPU / DirectML / CUDA）
├── packages/asr_align/             EPUB/文本 ↔ 音频匹配、句界重切、CTC 强制对齐
├── packages/asr_server/            HTTP API + 内置最小界面
├── packages/asr_cli/               `asr` 可执行：transcribe / serve / models
└── assets/models/                  内置模型清单 JSON（可被用户清单覆盖 / 扩展）
```

包边界的理由：Hibiki 只要 `asr_core` + `asr_align`（它自带 Flutter 插件后端），不该被迫吃进
`dart:ffi` 和 HTTP 服务器依赖；反过来 CLI/服务端不该吃进 Flutter。单包做不到按需依赖。

## 分阶段

### 阶段 1 — 仓库骨架 + `asr_core` 抽取（本轮主体）
1. 仓库骨架、LICENSE、pub workspace、README。
2. 24 个 `asr/` + `onnx/` 文件搬进 `asr_core`，`package:fushi/src/...` → `package:asr_core/src/...`。
3. 脱 Flutter：`foundation` → `package:meta` + 自带 `asrLog()`；`compute()` → `Isolate.run`；
   `listEquals` → `package:collection`。
4. `AsrModelStore` 砍掉 `AppPaths` 依赖（构造函数已经能注入目录，只有 `open()` 里那一处）。
5. `OnnxSessionFactory` 接口补上 `availableAcceleratedProviders()` / `deviceMemoryBudgetBytes()`
   （现在这两个挂在 ORT 实现上，导致三个测试被钉在 `flutter_onnxruntime` 类型上）。
6. `asr_pcm_source.dart` 摘掉 mobile-only 的 `ffmpeg_kit_flutter`，桌面路径本来就是 `Process.start`。
7. 迁 25 个测试（`package:test` 而非 `flutter_test`），`dart analyze` + `dart test` 全绿。

**必须注意**：`asr_types.dart` 是几乎所有模块的公共基础类型文件，它那条
`import 'package:flutter/foundation.dart'` 在编译期把整条依赖链钉死在 Flutter SDK 上。
脱 Flutter 必须**先**做，测试迁移才谈得上「改 import 即可」。

### 阶段 2 — 模型清单数据化（「支持配置其他模型」）
`asr_model_manifest.dart`（907 行硬编码 17 语言表）改成：

- **schema**：`{id, displayName, languages[], architecture: transducer|ctc, sampleRate,
  indexType: int32|int64, decoderContextSize, blankToken, files[{role,url,sha256,bytes}], tokens}`
- 内置清单落 `assets/models/builtin.json`，与硬编码表逐字段等价（用现有 907 行做真相源）
- 用户清单：`--models <file.json>` / `ASR_MODELS_MANIFEST` / 模型目录下的 `manifest.json`，
  与内置清单按 `id` 合并（用户覆盖内置）
- 允许纯本地模型（`file://` 或相对路径，无需下载）

### 阶段 3 — `asr_onnx_ffi`：纯 Dart ORT 后端
服务端没有 Flutter 引擎，必须自带 ONNX 后端。调研结论：pub.dev 上**没有**任何包同时满足
「纯 Dart + `AddFreeDimensionOverrideByName` 高层暴露 + DirectML」，得自己写 ffigen 绑定。

约 28 个 `OrtApi` 成员 + 3 个顶层符号即可闭环。已知必踩的坑：

- **`ORTCHAR_T` 在 Windows 是 `wchar_t`**，其它平台是 `char`。跨平台 ffigen 产物会静默传乱码
  路径 → **只用 `CreateSessionFromArray`（吃 bytes）彻底绕开**。
- **`AddFreeDimensionOverride` ≠ `AddFreeDimensionOverrideByName`**。前者匹配 ONNX `denotation`，
  后者匹配 `dim_param`（我们要的 `N` / `T`）。调错**既不报错也不生效**，编码器直接慢 5~7 倍。
- **DirectML 不是 `SessionOptionsAppendExecutionProvider(name,...)` 能启用的**（该函数只认
  QNN/OpenVINO/XNNPACK/WebNN/WebGpu/Azure/Js/VitisAI/CoreML）。必须
  `GetExecutionProviderApi("DML",...)` → `OrtDmlApi::SessionOptionsAppendExecutionProvider_DML`，
  并且强制 `DisableMemPattern()` + `ORT_SEQUENTIAL`。`dart_onnx` 这个包在这里是**静默回落 CPU**。
- **ORT 的 C ABI 严格尾部追加**：1.22→main 删除 0 项、顺序改动 0 处，用老头文件的表打新 runtime 是
  ORT 自己的 ABI 承诺。
- **动态库走 NuGet nupkg + HTTP Range 取单文件**，不要走 GitHub Releases（win-x64 整包 75 MB 里
  92% 是 pdb；Linux/mac 的 tgz 里是符号链接链，Dart 的 tar 库处理不当会解出坏文件）。
  DirectML 从 1.23 起 GitHub Releases 完全不再提供资产。
- **DirectML 把 ORT 钉死在 1.24.4**（NuGet 最新，2026-03，官方已转 sustained engineering）。
  只要 CPU 就钉 1.22.1（头文件自包含，ffigen 最省事）。
- Windows 干净机器缺 MSVC Redist → `DynamicLibrary.open` 直接失败，要显式报错而不是玄学崩。

**预期性能：持平到略优（1.0~1.3×）**。同一个 ORT + 同一个 DML EP + 同样的 free dim override，
图层完全一样；净收益来自消除 method channel —— 输入省两次拷贝，int64 输出省掉
`List<dynamic>` 装箱（silero VAD 每 32 ms 一次往返那类小张量路径受益最大）。
风险在 delta #9/#11 的双队列 + 每 session 一队列要在 Dart isolate 上重新实现，做砸了会掉到 0.7×。

### 阶段 4 — `asr_cli`
```
asr transcribe <音视频> [--lang ja] [--model <id>] [--out out.srt] [--format srt|vtt|json]
                       [--server http://host:port]   # 不带则本机跑
asr serve [--port 8080] [--host 127.0.0.1] [--token <api-token>]
asr models list | pull <id> | path
```
一份二进制两种用法：`transcribe` 不带 `--server` 就本机直接跑，带了就当远程客户端。

### 阶段 5 — `asr_server`
- `POST /v1/transcribe`（multipart 上传或 `{"path": ...}` 本地路径）→ 任务 id
- `GET /v1/jobs/{id}` 进度 SSE / 轮询；`GET /v1/jobs/{id}/result?format=srt`
- `GET /v1/models`、`POST /v1/models/{id}/pull`
- 内置最小静态界面（拖文件 → 选语言 → 进度 → 下载 SRT），随二进制打包
- `--token` 简单鉴权 + 并发闸门（GPU 会话不能并发建，显存会炸）

### 阶段 6 — `asr_align`
搬 `epub_srt_matcher.dart`(991) + `anchor_gap_filler.dart`(1133) + `cue_sentence_resegmenter.dart`(558)
+ `audio_text_normalizer.dart`(123) + `asr_ctc_align.dart`(320)。

**cue 类型边界**：这些文件直接吃 `AudioCue`，而 `AudioCue` 住在 `fushi_audio` 且带两个 drift
适配（`fromRow` / `toCompanion`）和一个 Hibiki 专用瞬态字段 `markup`。
**决定：新仓库定义自己的纯 `AsrCue`**，Hibiki 在两个导入入口做 `AudioCue ↔ AsrCue` 转换。
理由：零风险不动 Hibiki 的 DB 层，对外 API 也干净；代价只是边界处两个转换函数。

### 阶段 7 — Hibiki 改为引用新仓库
```yaml
dependencies:
  asr_core:
    git: {url: https://github.com/hajisensai/fushi-asr.git, path: packages/asr_core, ref: <tag>}
  asr_align:
    git: {url: ..., path: packages/asr_align, ref: <tag>}
```
本地开发用 `dependency_overrides` 的 `path:`。Hibiki 侧保留
`onnx_inference_ort.dart`（Flutter 插件后端）作为 `OnnxSessionFactory` 的另一个实现 ——
**移动端仍然只能走插件**，FFI 后端只服务桌面/服务端。

验证门：`flutter analyze` 全量 + `dart run tool/flutter_test_failures.dart --no-pub` 全量 +
目录枚举型守卫整批 51 条 + ASR E2E（`asr_transcribe_e2e_itest.dart`）真机跑过，
转写结果与改前**逐字节相同**。

## 不做

- **浏览器端 WASM 推理**：明确排除。（顺带记录调研结论，免得以后有人再问：WebGPU EP 对
  int8 zipformer 完全无用 —— `MatMulInteger` / `DynamicQuantizeLinear` / `QuantizeLinear` /
  `ConvInteger` 在 WebGPU EP 里注册数是 0；iOS Safari 上 ORT 官方 wasm 声明 shared+max 4GB，
  是可复现的 OOM 触发条件。）
- 移动端 FFI 后端：Android/iOS 继续走 Flutter 插件。
- 把 Hibiki 的模型下载 UI（Flutter widget）搬过去：那会让新仓库被迫依赖 Flutter。
