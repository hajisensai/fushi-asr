/// 日文正文归一化：白名单剥离 + 码点折叠原语。
///
/// **刻意不并进 `asr_core.dart`**：`AudioTextNormalizer` 与那几个折叠原语是从宿主
/// （Hibiki）抽出来的同源实现，宿主自己那份还在原地服务有声书匹配。把它们塞进
/// 主入口会让任何同时 import `fushi_asr_core` 与宿主音频包的文件当场 ambiguous
/// （实测：宿主一条既有测试立刻炸）。要用的人显式 import 这个入口。
library;

export 'src/text/audio_text_normalizer.dart';
export 'src/text/jp_codepoint_fold.dart';
