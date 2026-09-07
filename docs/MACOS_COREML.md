# macOS CoreML 后端

## 第四轮：Apple 原生文件输入与 Mac 调度实测

Apple SpeechTranscriber 现在先直接使用 `AVAudioFile` 读取 M4B/AAC/WAV 等系统支持的
原文件，省去先用 ffmpeg 把整本音频转换、写入临时 16 kHz 单声道 PCM 的步骤。
只在原生**打开文件失败**时兼容解码并重试一次；语音资源、模型、分析过程的错误
不会触发隐藏重跑。任务取消仍会终止并回收专属 helper/ffmpeg 进程。
依据是 [Apple 的文件输入 API](https://developer.apple.com/documentation/speech/speechanalyzer/start%28inputaudiofile%3Afinishafterfile%3A%29)。

M4 / macOS 27 / 五分钟样本 / old-direct-direct-old 顺序，各模式两次中位数：

| Apple 输入 | 旧预处理＋转录 | 原生直读＋转录 | 输出检查 |
|---|---:|---:|---|
| 16 kHz WAV | 3.597 s | 3.467 s | 字幕文本及时间戳相同 |
| AAC/M4B | 3.417 s | 3.298 s | 28 条字幕，26 条文本相同，最大结束时间差 60 ms |

短样本只快约 3–4%，可能包含预热/系统负载波动，不声称模型计算大幅提速。
确定的改进是移除整本 PCM 临时文件及提前解码等待：9:31:03 的音频原先会额外
落盘约 1.02 GiB PCM（不含 WAV 头）。AAC 现在使用 Apple 的解码/重采样路径，
可能改变少量识别文本；相似度不是准确率，未做人工 CER。
原始记录：`build/benchmark/apple-native-direct-g_2up565/results.json`。

若某文件在打开后读取失败，或需要复现旧预处理结果，可显式使用兼容模式：

```bash
ASR_APPLE_COMPAT_PCM=1 ./script/build_and_run.sh
# 同一个 helper、相同样本，对照完整预处理与直接输入（串行 ABBA）：
python3 tool/benchmark_apple_input.py /path/to/book.m4b \
  --helper build/apple_transcribe --offset 120 --duration 300 --rounds 2
```

Mac FFI 线程诊断新增以下开关，**均未改变生产默认策略**：

- `ASR_MACOS_GREEDY_SESSIONS`、`ASR_MACOS_GREEDY_THREADS`、`ASR_MACOS_BATCH_SIZE`
  接受 1..64，分别覆盖 greedy 会话数、其线程数和音频批预算。
- `ASR_MACOS_CPU_THREADS` 限制未显式指定线程的 CPU 会话，不覆盖 greedy 显式设置。
- `ASR_MACOS_ORT_SPINNING=0|1` 调整 ORT 等待时的线程自旋。
- `ASR_COREML_SPECIALIZATION=Default|FastPrediction` 单独测试 CoreML 加载/预测权衡，
  磁盘缓存按该选项隔离；未设置保留原缓存。

所有参数只在 Mac 对应路径生效，不改变 Windows/CUDA/DirectML 策略；更改后须重启服务。
依据：[ORT 线程文档](https://onnxruntime.ai/docs/performance/tune-performance/threading.html)、
[CoreML 参数文档](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)。

线程扫描没有稳定胜出的组合，因此未默认减少会话、关闭自旋或减少线程。
INT8 单 greedy 会话还改变了部分输出，不能把它当作无损优化。
测量期间存在其他应用 CPU 负载变化；不将不同时间段的最快单次结果作为提速结论。
记录在 `build/benchmark/20260907-194704-mac-threads-2b1a7a02/`（CoreML）和
`build/benchmark/20260907-195036-mac-threads-19223605/`（CPU）。

`FastPrediction` 也没有稳定优势：ABBA 四组热请求中位数依次为默认 13.125 s、
FastPrediction 10.056 s、FastPrediction 9.695 s、默认 9.239 s。
默认组自身波动很大，末组默认还更快，因此没有开启它。所有 FP32 字幕/时间戳一致。
第一次 FastPrediction 请求为 33.671 s，含该命名空间首次编译，不能与已有缓存的
默认首次请求直接比较。证据：`build/benchmark/20260907-195228-mac-threads-648a40d1/`。

```bash
source script/env.sh
dart compile exe tool/reazon_benchmark.dart -o build/reazon_macos_round4
python3 tool/benchmark_macos_threads.py /path/to/sample.wav
python3 tool/benchmark_macos_threads.py /path/to/sample.wav --cpu \
  --configs baseline,single,greedy1,greedy1,baseline
```

该脚本对所有组固定 `RequireStaticInputShapes=1`，每次用相同字节的唯一任务文件，
检查真实 provider 和字幕/时间戳，分别报告首个请求与后续请求。CPU 每请求仍装载会话；
CoreML 后续请求复用会话。`decode_stats` 是包含 await 调度等待的阶段跨度，可能重叠，
不能相加当总时间，也不能当纯 CPU 算子耗时。

本轮验证：`asr_core` 334 项通过、1 项 Windows 二进制用例跳过；
`asr_onnx_ffi` 32 项、`asr` 33 项通过（含 15 项 Apple 输入/取消/失败回退测试）。
Swift helper 以 macOS 26 deployment target release 编译通过，日语资源状态 ready。
静态分析只剩已有两个 DML C ABI 命名提示。
测试时另一任务正在同一工作区接入字幕对轴接口，服务端因尚未补齐的对轴符号暂不能编译；
本轮没有覆盖其改动、重启旧服务或刷新用户结果页。整服务回归须在该集成完成后执行。
可用 `dart run tool/verify_macos_api.dart <长音频> <短音频> <同卷EPUB>` 验证
三种后端的真实取消、随后生成 EPUB 对齐结果和实际 provider（此工具本轮未执行）。

## 当前更新：无侧栏、可终止、CoreML 分区优化

界面默认选择 `Fushi 原版 · CPU（推荐）`：日语用 ReazonSpeech INT8，
不是把 CPU 冒充 CoreML。Apple 和 `ReazonSpeech · CoreML（实验）` 仍可单独选择。
比较按钮默认跑 Apple + 原版 INT8；选中 CoreML 时改为 Apple + CoreML，
按钮旁明确显示比较对象。其余 17 种语言的入口和 Windows 后端策略保留。

CoreML 现在默认 `RequireStaticInputShapes=1`：仅将输入形状已知的**子图**
交给 CoreML，未覆盖的节点留给 ORT CPU。**没有强行固定整个模型的 N/T**，
没有启用之前触发 Metal 断言的静态桶，也未改变模型权重或开启低精度累加。
计算单元仍为 ALL，不保证每个算子都落到 GPU/ANE。
配置含义见 [ORT CoreML 文档](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)。

M4 / 同一 300 秒日语音频 / 独立文件名避免命中字幕缓存 / 每组首次 + 3 次热请求：

| CoreML 参数 | 首次请求 | 热请求中位数 | 与原 FP32 字幕逐字及时间戳一致 |
|---|---:|---:|---|
| 原动态分区（复测） | 21.990 s | 9.352 s | 是 |
| 仅接收静态输入子图（已启用） | 13.056 s | 5.877 s | 是 |
| CPUAndGPU / 动态分区（未采用） | 25.371 s | 14.205 s | 是 |

本轮热运行提速 **1.59×**，约 **51× 实时**。首次请求包括会话加载，系统和模型转换
缓存没有清空，不能称为磁盘冷启动。以上未做人工 CER 或整卷速度保证。
另轮原版 INT8 CPU 四次完整请求为 5.557 / 5.575 / 5.518 / 5.914 秒，均包含
会话装载；INT8 与 FP32 的字幕并非逐字相同，不能把量化称为无损。
减至 1/2/4 个编码器线程也未改善速度，没有更改默认线程策略。

原始诊断数据：`build/benchmark/20260907-191430-tuning-780f895a/`，
线程/INT8 对照：`build/benchmark/20260907-190758-tuning-4c5bb783/`。
两组是顺序执行而非严格交错、恒温基准，运行间负载存在波动。

复现同版本 A/B（每次都复制相同 WAV 为唯一任务名）：

```bash
source script/env.sh
dart compile exe tool/reazon_benchmark.dart -o build/reazon_tuning
python3 tool/benchmark_coreml_tuning.py /path/to/sample.wav --partition
```

诊断开关仅作用于 macOS CoreML 会话：`ASR_COREML_STATIC_INPUTS=0` 可回退原分区，
`ASR_COREML_ENCODER_THREADS=1` / `ASR_COREML_COMPUTE_UNITS=CPUAndGPU` 仅供 A/B。
改变配置后须重启常驻服务；转换缓存按分区选项与计算单元隔离。CPU、CUDA、DML
不读取这些 CoreML 执行参数。Windows 未做真机回归，原有暂停行为和 334 项核心测试通过。

### 终止协议

1. `POST /v1/jobs` 获取随机 `jobId`（未提交的保留 5 分钟，数量有上限）。
2. `POST /v1/transcribe?...&jobId=...` 上传并开始任务；不传 ID 的旧调用仍兼容。
3. `POST /v1/jobs/{jobId}/cancel` 使用相同 Bearer 鉴权。返回时任务资源和队列槽
   已释放；不是只中断浏览器读取。未断开的 NDJSON 流以 `phase: cancelled` 结束。

界面显示「正在停止」直到确认。上传/排队均可终止；Apple 会结束该任务的 ffmpeg / helper；
Reazon 在安全批次检查点停止并跳过尚未提交的批次，释放或归还会话，删除本次取消任务的
临时上传和未完成中间产物；EPUB 解析/对齐的纯 Dart isolate 可直接终止。
不会杀掉承载 ORT 会话的 isolate，以免泄漏 native 资源。模型首次加载、正在执行的 native
调用不能保证瞬停。原有普通「暂停并续跑」仍保留完整检查点语义，未改为丢弃未提交批次。

界面实测（真实 EPUB + 300 秒音频）：CPU 转录中确认终止 3.35 秒，Apple 0.047 秒，
CoreML 模型加载中 6.87 秒、热转录中 0.204 秒；都能随后重新生成完整字幕。
双方案第一项终止后不会启动第二项，已经完成的字幕保留。关闭/重载页面仍会丢失页面结果。

以下为前几轮记录，旧速度和默认设置不代表上述更新后的表现。

## 界面实测（EPUB＋音频、Apple / Reazon 对比）

执行 `./script/build_and_run.sh`，打开 `http://127.0.0.1:8642/`。
启动脚本会构建 Apple SpeechTranscriber helper 并检查日语语音资源。
界面默认要求选择同卷 EPUB 和音频；可勾选「仅转录音频」保留旧流程。
完整流程是：按 OPF spine 解析正文（含 ruby 注音轨）→ 音频转录 → 正文匹配与
锚点回填 → 有 token 时间时重切句界 → 命中部分替换为正文，未命中部分保留转录。
Apple 当前只提供片段时间，所以校准文字但保留原始片段边界，不按字数伪造时间戳。
Reazon 会读取 token 时间 sidecar，供已有句界重切算法使用。

macOS 提供 Apple SpeechTranscriber、ReazonSpeech CoreML，以及原有多语言模型入口。
语言列表恢复注册表中的全部 17 种（自定义注册表还可扩展），不再随 Apple/日语选择
被过滤。Apple/CoreML 当前只声明已适配的日语；选其他语言会切到原有模型，
不支持所选语言的方案保留可见并置灰。恢复语言入口不代表所有模型已下载、
所有语言的 EPUB 对齐质量或 CoreML 支持已经验证。

「两种方案各生成一次」对同一 EPUB＋音频依次跑 Apple 和 Reazon CoreML，
不会把多语言 CPU 入口算作第三次测试。输出分别展示正文解析、转录、对齐和总耗时，
正文匹配数、未匹配数和句界变化，并提供「对齐字幕」「原始转录」两份下载。
匹配率不是人工 CER 准确率。支持 SRT / WebVTT / JSON；Windows 和 `serve --cpu`
保留原有默认后端和全部语言。未传 engine 的 API 调用保持原先 runner 语义。

`GET /v1/backends` 返回方案和可用状态；`POST /v1/transcribe?language=ja&engine=apple`
或 `engine=coreml` 选择后端。未安装语音资源或不支持的后端会明确显示不可用。
EPUB 工作流使用 `multipart/form-data`，字段名为 `epub` 和 `audio`，各一个；
原有原始音频 body 仍可使用。EPUB 最大 64 MiB、单个正文条目解压后最大 4 MiB、
全部读取正文最多 32 MiB；只在内存读取容器内路径，不向磁盘解压或获取外链。
异常 EPUB 在转录前拒绝；临时上传文件在请求结束后清理。
每次上传生成唯一任务名，保证重复同文件也真实转录，不会复用已完成字幕。
Apple 处理时间包括 ffmpeg PCM 转换和原生进程启动；它不是 ONNX 后端，
结果 provider 标为 `apple-speechtranscriber`，不冒充 CoreML EP 或 CPU EP。
CoreML 保留常驻会话：首次请求和热请求耗时不可直接当成相同加载条件的比较。

2026-09-07 实际界面验证：第 1 卷 EPUB（20 个正文片段）＋02:00 起 60 秒音频，
Apple 总处理 1.271 秒（转录 1.136 秒、对齐 0.111 秒），匹配 6/6，输出 6 条；
CoreML 首次总处理 15.987 秒（转录 15.791 秒、对齐 0.174 秒），匹配 19/19，
新增 1 个句界、移除 3 个句界，输出 17 条。不是整卷质量验证或多轮速度基准。
页面已验证 17 个语言选项、英/中/德/阿拉伯语切换、双文件必填、双方案生成、
对齐/原始字幕下载、1280×1100 与 390×844 布局、无控制台错误。

CoreML 已接入 ONNX Runtime FFI：FP32 编码器使用 MLProgram，计算单元设为 ALL，
由 CoreML 决定 CPU / GPU / Neural Engine 分配；decoder、joiner、VAD 和 greedy
Loop 仍走 CPU。此设置不保证所有算子都在 GPU 或 Neural Engine 上执行。

## 使用

在 Bash 终端中运行（或直接用项目本地 `.tools/dart-sdk/bin/dart`）：

```bash
source script/env.sh
dart run packages/asr_cli/bin/asr.dart models pull -l ja --variant fp32
dart run packages/asr_cli/bin/asr.dart transcribe --coreml -l ja /path/to/audio.m4b
dart run packages/asr_cli/bin/asr.dart serve --coreml
```

`--coreml` 与 `--cpu` 互斥。不支持 macOS CoreML 的运行时会明确报错。
若模型会话创建失败，沿用已有 CPU 回退机制，最终 provider / fallback reason
会反映该结果。模型内部未被 CoreML 支持的节点仍由 ORT CPU 执行。
自动模式保留 INT8 CPU；本次基准证明当前日语导出不适合直接将 CoreML 作为默认。

模型转换缓存位于 ASR 数据目录下 `coreml_cache/`，按 ORT 版本、模型内容
SHA-256、图优化选项和维度覆盖隔离，避免使用同结构、不同权重的旧缓存。CoreML 任务另存
`asr_jobs/coreml-fp32/`，不会借用之前 INT8 CPU 已完成的断点记录。

## M4 实测（2026-09-07）

设备：Apple M4、16 GiB、macOS 27.0；Dart 3.13.3 AOT、ONNX Runtime 1.29.0。
素材：用户本机《無職転生》第 1 卷 02:00 起的 60 秒和 300 秒片段。
每个引擎每个长度运行三轮，顺序交替、不同进程、唯一任务文件名、相同 PCM 字节。
下面是三轮端到端耗时中位数；下载、编译可执行文件、音频截取不计时。
CoreML 模型转换缓存已建立，但每次新建会话的模型加载仍计入耗时。

| 音频 | Apple SpeechTranscriber | Reazon INT8 CPU | Reazon FP32 CoreML |
|---|---:|---:|---:|
| 60 秒 | 1.004 秒 | 1.518 秒 | 16.123 秒 |
| 300 秒 | 3.240 秒 | 3.824 秒 | 23.727 秒 |

CoreML 是真的被执行了，并非静默回退为纯 CPU：

- ORT 记录：5,295 个图节点中 1,362 个被 CoreML 接收，拆为 263 个子图。
- 一分钟诊断运行的 profile 中有 1,578 次 `CoreMLExecutionProvider` 内核事件；
  同时有 23,598 次 CPU 内核事件。事件数量不是耗时占比。
- 首次带 profiling 的诊断运行耗时 21.609 秒，其中 ORT 会话初始化约 12.58 秒。
  诊断运行单列，不与未开启 profiling 的三轮结果混合。
- 两个长度都返回完整范围的非空转录，分别为 19 和 90 条 cue。
- 微型 FP32 图在多组输入、重复推理下与 CPU 输出误差不超过测试容差 0.005。
  实际有声书未做人工 CER 标注，不据此宣称准确率不变。

结果：当前动态形状 Reazon ONNX 导出在 CoreML 中高度分割，加载和跨后端执行
成本明显；本机一分钟、五分钟耗时分别约为 INT8 CPU 的 10.6 倍、6.2 倍。
进一步优化应针对图覆盖率、固定形状与会话复用进行，不能把“开启 CoreML”
直接等同于“获得加速”。

## 复现与诊断

```bash
./script/benchmark_macos.sh /path/to/audio.m4b \
  --offset 120 --durations 60 300 --runs 3 --engines apple reazon coreml

# 单独捕获 CoreML 编码器的 ORT profile；该次耗时包含 profiling 开销。
ASR_ORT_PROFILE_DIR="$PWD/build/coreml-profile" \
  ./script/benchmark_macos.sh /path/to/audio.m4b \
  --durations 60 --runs 1 --engines coreml
```

三方原始结果：`build/benchmark/20260907-170100-74c6cfcc/`。
首次诊断：`build/benchmark/20260907-170013-3400abfd/`。
Profile：`build/coreml-profile/`。音频、转录、缓存均保留在本机。

配置依据：[ONNX Runtime CoreML 文档](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)。

## 第二轮：macOS 常驻会话优化

`TranscribeRunner(forceCoreMl: true)` 现在默认复用同一后台 isolate 中的模型会话。
编码器和 CPU 解码会话只在首次任务装载；每个任务仍新建解码器状态和任务状态，
不会复用上一段音频的 token 或字幕。任务串行执行，不会把同一个 native 会话并发
借给两个任务。切换语言、任务失败时清理缓存；显式 `runner.close()` 等待已接收任务
完成后释放全部会话。模型会常驻内存，调用者应在结束使用时关闭 runner。

- `asr serve --coreml`：同一服务的后续请求受益，退出服务时释放。
- 单次 `asr transcribe --coreml`：依然包含首次加载，不能获得跨进程会话复用收益。
- Dart 宿主：保留一个 runner，最后在 `finally` 中 `await runner.close()`。
- `reuseCoreMlSessions: false` 可回到原先每任务独立 isolate 的路径，供 A/B。
- 仅 `Platform.isMacOS && forceCoreMl` 开启。Windows CUDA/DirectML 后端选择、
  模型、静态桶和现有 isolate 路径不变；本轮未在 Windows 真机跑 GPU 回归。

### 同一有声书，真实任务 A/B

每个长度 4 次独立会话请求，对比同一个常驻 worker 的首次请求 + 3 次热请求。
每个任务使用全新文件名，文件 SHA-256 相同，不复用已完成任务记录。
请求耗时包括 PCM 解码、特征提取、推理和字幕输出；热请求不含首次装载，
也不含最后关闭 worker 的耗时。未清系统缓存，不能称为冷启动基准。

| 音频 | 独立会话中位数（4 次） | 常驻首次 | 常驻热中位数（3 次） | 热请求提速 |
|---|---:|---:|---:|---:|
| 60 秒 | 16.252 秒 | 15.674 秒 | 2.346 秒 | 6.93× |
| 300 秒 | 27.464 秒 | 31.023 秒 | 14.082 秒 | 1.95× |

每个长度的 8 份输出（19 / 90 条 cue）文本及时间戳完全一致。
这验证了会话复用未改变这些样本的输出，不是人工标注 CER 测试。
300 秒独立会话的四次耗时为 24.728 / 25.195 / 29.732 / 30.406 秒，存在运行间
波动；不同轮次不能当成严格同温、同负载的比较。CoreML 仍未超过前一轮的
INT8 CPU / Apple SpeechTranscriber，因此没有修改默认后端。

原始结果：`build/benchmark/20260907-171632-reuse-f98fa7f5/results.json`。

```bash
source script/env.sh
dart compile exe tool/reazon_benchmark.dart -o build/reazon_benchmark
python3 tool/benchmark_coreml_reuse.py \
  build/benchmark/20260907-165302/sample-60s.wav \
  build/benchmark/20260907-165302/sample-300s.wav
```

### 固定形状 / 图优化实验（没有启用到正式转录路径）

用完整 FP32 编码器、确定性合成特征 `[2,560,80]`、`x_lens=[460,560]`，
4 个 ORT CPU 线程，对照同输入 CPU 输出。此实验只测编码器，不代表音频端到端速度。

- 仅固定 `N/T`：263 个子图降为 257 个，但在本机触发 Metal
  `mps.matmul contracting dimensions differ 1 & 48` 断言，进程以 134 退出。
  必须用独立诊断进程运行；Dart 异常捕获无法兜住 native abort。
- 动态形状 + BASIC 优化：仍为 263 子图 / 1,362 支持节点，没有改善分区。
- 动态形状 + `RequireStaticInputShapes=1`：192 子图 / 1,124 支持节点；
  热推理中位数 0.195 秒，CPU 对照约 0.167 秒。
- 固定形状 + `RequireStaticInputShapes=1`：本轮能完成，198 子图 / 1,196 支持节点；
  热推理中位数 0.246 秒，CPU 对照约 0.181 秒。相对 L2 误差约 1.15e-6。

因此没有简单套用 Windows 的静态桶。FFI 工厂保留两个默认关闭的实验开关
`coreMlBasicOptimizations` 和 `coreMlRequireStaticInputShapes`；普通 CPU、CUDA、
DirectML 会话不受这些开关影响。诊断产物：`build/coreml-*.json` / `build/coreml-*.log`。

```bash
dart compile exe tool/coreml_encoder_benchmark.dart -o build/coreml_encoder_benchmark
build/coreml_encoder_benchmark /path/to/encoder.onnx --static --static-only
```

下一步需要针对 Reazon 导出图中的动态形状运算和 CoreML 不支持的算子做专门改写，
用独立 macOS 派生模型验证，不能靠增加线程或直接沿用 Windows 桶表保证加速。

### 回归验证

`asr_core` 333 通过、1 平台相关跳过；`asr_onnx_ffi` 22 通过；`asr` 13 通过；
`asr_server` 10 通过，共 378 项通过。新增覆盖会话借还、并发借用隔离、模型变更、
shape / provider / 线程数缓存键、回退不缓存、加载中关闭保护，以及 worker 错误传播、
排队和初次启动期间关闭。相关代码静态分析无新增问题（保留两项原有 DML 命名提示）。
