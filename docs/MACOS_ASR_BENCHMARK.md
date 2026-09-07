# macOS 日语转录速度实测

后续已接入 CoreML，三方对比见 [MACOS_COREML.md](MACOS_COREML.md)。下文保留
首次 Apple / CPU 对比的数据和当时的实现状态。

2026-09-07，在 Apple M4、16 GiB 内存、macOS 27.0 上比较系统
SpeechTranscriber 与当前项目的 ReazonSpeech k2-v2（INT8、CPU）。
Dart 3.13.3 AOT、ONNX Runtime 1.29.0；项目基线为 `7eb70dc`。

## 实测结果

素材为用户本机《無職転生》第 1 卷有声书，从 02:00 开始截取两个片段。
各引擎、各片段运行三次。下表为从启动进程到完整 JSON 输出并退出的中位耗时。

| 音频长度 | Apple SpeechTranscriber | ReazonSpeech k2-v2 CPU | 苹果速度 / Reazon 速度 |
|---|---:|---:|---:|
| 60 秒 | 0.791 秒（75.9 倍实时） | 1.537 秒（39.0 倍实时） | 1.94 倍 |
| 300 秒 | 3.207 秒（93.5 倍实时） | 3.755 秒（79.9 倍实时） | 1.17 倍 |

每轮原始耗时（秒）：

| 音频长度 | 引擎 | 第 1 轮 | 第 2 轮 | 第 3 轮 |
|---|---|---:|---:|---:|
| 60 秒 | Apple | 0.885 | 0.791 | 0.782 |
| 60 秒 | Reazon | 2.177 | 1.503 | 1.537 |
| 300 秒 | Apple | 3.211 | 3.207 | 3.172 |
| 300 秒 | Reazon | 3.823 | 3.755 | 3.725 |

此次苹果在两个长度上均更快，但长片段差距明显缩小。不能据此断言苹果
对所有日语素材都快一倍，也不能把这项速度测试作为识别准确率排名。

## 计时边界与限制

- 两边使用完全相同的 16 kHz、单声道、PCM s16 WAV，保留 SHA-256。
- 安装模型、编译程序、从 M4B 提取 WAV 均不计入转录耗时。
- 每轮都新建进程，交替 Apple/Reazon 先后顺序，不并发跑识别。
- 没有清理系统模型缓存或文件缓存；第 1 轮不代表严格冷启动。
- 每轮使用唯一音频文件名，避免 Reazon 按文件名和大小复用已完成的任务。
  模型及派生计算图缓存保留，符合重复使用应用的场景。
- Apple 计时包括系统转录调用及结果收集；Reazon 计时包括模型装载、
  FFmpeg PCM 读取、VAD、特征计算、推理、字幕整理和任务写盘。
  这是当前可用转录流程的比较，不是纯模型算子吞吐量比较。
- 两边均返回了覆盖片段的非空转录结果。分段规则不同，cue 数量不能用来
  比较准确率。没有人工标注 CER，也没有测内存、功耗或实时首字延迟。
- 当前 Reazon 后端未启用 CoreML，本结果不代表硬件加速优化后的上限。
- 苹果模型由系统管理更新；后续系统版本的结果可能变化。

## 复现

```bash
./script/benchmark_macos.sh '/absolute/path/to/audio.m4b'
# 自定义截取起点、长度和轮数
./script/benchmark_macos.sh '/absolute/path/to/audio.m4b' \
  --offset 120 --durations 60 300 --runs 3
```

需要 Apple Silicon、macOS 26+、Swift 工具链，以及先前配置的 Dart、FFmpeg、
ONNX Runtime。脚本会安装苹果日语资产和 Reazon INT8 模型，然后执行测试。
输出包含 `results.json`、`REPORT.md`、每轮 JSON 转录结果和 stderr 日志，
位于已被 Git 忽略的 `build/benchmark/<时间>/`。源音频不会被修改或上传。

本次有效结果：`build/benchmark/20260907-165302/`。
早期 `20260907-165203` 为发现断点缓存问题的无效试跑，不能用于性能结论。
