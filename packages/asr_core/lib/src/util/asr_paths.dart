/// 数据根目录解析。
///
/// 抽包前这里直接调 Hibiki 的 `AppPaths.supportRootDirectory()`，那是把库钉在宿主
/// 应用上的一条依赖。现在做成**可替换的单点**：纯 Dart 宿主（CLI / 服务端）用下面
/// 的默认实现，Flutter 宿主开机时把自己的 `AppPaths` 装进来即可，模型缓存与任务
/// 目录仍落在应用自己的数据根下，与抽包前逐字一致。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 数据根解析器签名。
typedef AsrSupportRootResolver = Future<Directory> Function();

/// 当前数据根解析器。宿主可整体替换。
AsrSupportRootResolver asrSupportRootResolver = defaultAsrSupportRoot;

/// 数据根：模型缓存（`asr_models/`）与转录任务目录（`asr_jobs/`）的父目录。
Future<Directory> asrSupportRootDirectory() => asrSupportRootResolver();

/// 纯 Dart 默认：`ASR_DATA_DIR` 环境变量 > 各平台常规用户数据目录 > 当前目录。
///
/// 不用 `Directory.systemTemp`：模型包动辄一两百 MB，落临时目录会被系统清掉，
/// 用户下次转录又要重下一遍。
Future<Directory> defaultAsrSupportRoot() async {
  final String? override = Platform.environment['ASR_DATA_DIR'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  final Map<String, String> env = Platform.environment;
  String? base;
  if (Platform.isWindows) {
    base = env['LOCALAPPDATA'] ?? env['APPDATA'];
  } else if (Platform.isMacOS) {
    final String? home = env['HOME'];
    base = home == null ? null : p.join(home, 'Library', 'Application Support');
  } else {
    base = env['XDG_DATA_HOME'];
    if (base == null || base.isEmpty) {
      final String? home = env['HOME'];
      base = home == null ? null : p.join(home, '.local', 'share');
    }
  }
  if (base == null || base.isEmpty) {
    return Directory(p.join(Directory.current.path, '.asr'));
  }
  return Directory(p.join(base, 'asr'));
}
