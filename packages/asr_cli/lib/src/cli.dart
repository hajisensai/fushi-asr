/// `asr` 命令行。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:asr/asr.dart';
import 'package:asr_server/asr_server.dart';

/// 建命令行。
CommandRunner<int> buildAsrCommandRunner() {
  final CommandRunner<int> runner = CommandRunner<int>(
    'asr',
    '多语言语音识别生成字幕。',
  )
    ..addCommand(TranscribeCommand())
    ..addCommand(ModelsCommand())
    ..addCommand(ServeCommand());
  runner.argParser
    ..addOption('models',
        help: '模型清单 JSON（与内置清单按 id 合并；也可用 ASR_MODELS_MANIFEST）')
    ..addOption('data-dir',
        help: '模型与任务目录的根（也可用 ASR_DATA_DIR）');
  return runner;
}

/// 解析出当前该用的注册表与数据根。
Future<({AsrModelRegistry registry, Directory? dataRoot})> _context(
  Command<int> command,
) async {
  final ArgResultsLike globals = ArgResultsLike(command);
  final String? dataDir = globals.option('data-dir');
  final Directory? root = dataDir == null ? null : Directory(dataDir);
  final AsrModelRegistry registry = await AsrModelRegistry.resolve(
    explicitPath: globals.option('models'),
    dataRoot: root ?? await defaultAsrSupportRoot(),
  );
  return (registry: registry, dataRoot: root);
}

/// 读全局选项：`args` 的全局选项挂在 runner 上，子命令里要往上走一层拿。
class ArgResultsLike {
  ArgResultsLike(this.command);
  final Command<int> command;

  String? option(String name) {
    final Object? v = command.globalResults?[name];
    if (v is String && v.isNotEmpty) return v;
    return null;
  }
}

// ---------------------------------------------------------------- transcribe

class TranscribeCommand extends Command<int> {
  TranscribeCommand() {
    argParser
      ..addOption('language',
          abbr: 'l', help: '语言标签（ja / en / zh / yue / …）。省略则按 --list-languages 里的清单选')
      ..addOption('output', abbr: 'o', help: '输出文件；省略写 stdout')
      ..addOption('format',
          abbr: 'f',
          defaultsTo: 'srt',
          allowed: <String>['srt', 'vtt', 'json'],
          help: '字幕格式')
      ..addFlag('cpu', help: '强制 CPU（不试 GPU EP）', negatable: false)
      ..addFlag('no-download',
          help: '缺模型时报错而不是自动下载', negatable: false)
      ..addOption('server',
          help: '把活交给远端 asr 服务端（http://host:port），本机不跑推理')
      ..addFlag('quiet', abbr: 'q', help: '不打进度', negatable: false);
  }

  @override
  String get name => 'transcribe';

  @override
  String get description => '把音视频转成字幕。';

  @override
  String get invocation => 'asr transcribe [选项] <音视频文件...>';

  @override
  Future<int> run() async {
    final List<String> paths = argResults!.rest;
    if (paths.isEmpty) {
      usageException('至少要给一个音视频文件');
    }
    final String formatName = argResults!['format'] as String;
    final SubtitleFormat format = SubtitleFormat.fromName(formatName)!;
    final bool quiet = argResults!['quiet'] as bool;
    final String? serverUrl = argResults!['server'] as String?;

    final ({AsrModelRegistry registry, Directory? dataRoot}) ctx =
        await _context(this);
    asrModelRegistry = ctx.registry;

    final String? tag = argResults!['language'] as String?;
    if (tag == null) {
      usageException(
        '要指定 --language。当前认得：'
        '${ctx.registry.languages.map((AsrLanguage l) => l.tag).join(", ")}',
      );
    }
    final AsrLanguage? language = AsrLanguage.fromTag(tag);
    if (language == null) {
      stderr.writeln(
        '不认识的语言标签 "$tag"。当前认得：'
        '${ctx.registry.languages.map((AsrLanguage l) => l.tag).join(", ")}',
      );
      return 2;
    }

    final String text;
    if (serverUrl != null) {
      text = await _viaServer(serverUrl, paths.single, language, format, quiet);
    } else {
      final TranscribeRunner runner = TranscribeRunner(
        registry: ctx.registry,
        dataRoot: ctx.dataRoot,
        forceCpu: argResults!['cpu'] as bool,
        missingModel: argResults!['no-download'] as bool
            ? MissingModelPolicy.fail
            : MissingModelPolicy.download,
      );
      final TranscribeOutcome outcome = await runner.run(
        audioPaths: paths,
        language: language,
        format: format,
        onProgress: quiet ? null : _printProgress,
      );
      if (!quiet) {
        stderr.writeln();
        stderr.writeln('完成：${outcome.cues.length} 条 cue，'
            '${_secs(outcome.audioMs)} 音频，用时 ${_secs(outcome.elapsed.inMilliseconds)}'
            '（${(outcome.audioMs / outcome.elapsed.inMilliseconds).toStringAsFixed(1)}× 实时），'
            'EP=${outcome.provider}');
      }
      text = outcome.text;
    }

    final String? out = argResults!['output'] as String?;
    if (out == null) {
      // 字幕走 stdout，日志与进度一律走 stderr —— 这样 `asr transcribe … > a.srt`
      // 拿到的是干净的字幕。
      stdout.write(text);
    } else {
      await File(out).writeAsString(text);
      if (!quiet) stderr.writeln('写入 $out');
    }
    return 0;
  }

  DateTime _lastPrint = DateTime.fromMillisecondsSinceEpoch(0);

  void _printProgress(TranscribeProgress p) {
    final DateTime now = DateTime.now();
    final bool terminal = p.phase == 'done';
    if (!terminal && now.difference(_lastPrint).inMilliseconds < 200) return;
    _lastPrint = now;
    final String pct = '${(p.fraction * 100).toStringAsFixed(1)}%'.padLeft(6);
    final String detail = p.detail.isEmpty ? '' : ' ${p.detail}';
    stderr.write('\r${p.phase.padRight(10)}$pct$detail   ');
  }

  Future<String> _viaServer(
    String baseUrl,
    String path,
    AsrLanguage language,
    SubtitleFormat format,
    bool quiet,
  ) async {
    final AsrClient client = AsrClient(Uri.parse(baseUrl));
    try {
      return await client.transcribeFile(
        File(path),
        languageTag: language.tag,
        format: format.name,
        onProgress: quiet
            ? null
            : (Map<String, Object?> json) => stderr.write(
                  '\r${json['phase']} '
                  '${(((json['fraction'] as num?) ?? 0) * 100).toStringAsFixed(1)}%   ',
                ),
      );
    } finally {
      client.close();
    }
  }
}

String _secs(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

// -------------------------------------------------------------------- models

class ModelsCommand extends Command<int> {
  ModelsCommand() {
    addSubcommand(_ModelsListCommand());
    addSubcommand(_ModelsPullCommand());
    addSubcommand(_ModelsExportCommand());
  }

  @override
  String get name => 'models';

  @override
  String get description => '看 / 下 / 导出模型清单。';
}

class _ModelsListCommand extends Command<int> {
  @override
  String get name => 'list';

  @override
  String get description => '列出当前注册表里的模型包与就绪状态。';

  @override
  Future<int> run() async {
    final ({AsrModelRegistry registry, Directory? dataRoot}) ctx =
        await _context(this);
    asrModelRegistry = ctx.registry;
    final Directory? root = ctx.dataRoot;
    if (root != null) asrSupportRootResolver = () async => root;

    for (final AsrModelPack pack in ctx.registry.packs) {
      final String langs =
          pack.languages.map((AsrLanguage l) => l.tag).join(' ');
      stdout.writeln('${pack.id}  [$langs]  ${pack.architecture.name}');
      stdout.writeln('  ${pack.displayName}');
      for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
        final AsrModelStore store = AsrModelStore(
          await _packDir(pack),
          pack,
        );
        final AsrModelStatus status = await store.status(variant);
        stdout.writeln('  ${variant.name.padRight(5)} '
            '${status.ready ? "已就绪" : "缺 ${_mb(status.totalBytes - status.obtainedBytes)}"}'
            '  共 ${_mb(status.totalBytes)}');
      }
    }
    return 0;
  }
}

class _ModelsPullCommand extends Command<int> {
  _ModelsPullCommand() {
    argParser
      ..addOption('language', abbr: 'l', help: '语言标签')
      ..addOption('variant',
          allowed: <String>['fp32', 'int8'],
          defaultsTo: 'int8',
          help: '编码器变体');
  }

  @override
  String get name => 'pull';

  @override
  String get description => '下载某语言的模型包。';

  @override
  Future<int> run() async {
    final ({AsrModelRegistry registry, Directory? dataRoot}) ctx =
        await _context(this);
    asrModelRegistry = ctx.registry;
    final Directory? root = ctx.dataRoot;
    if (root != null) asrSupportRootResolver = () async => root;

    final String? tag = argResults!['language'] as String?;
    if (tag == null) usageException('要指定 --language');
    final AsrLanguage? language = AsrLanguage.fromTag(tag);
    if (language == null) {
      stderr.writeln('不认识的语言标签 "$tag"');
      return 2;
    }
    final AsrEncoderVariant variant =
        (argResults!['variant'] as String) == 'fp32'
            ? AsrEncoderVariant.fp32
            : AsrEncoderVariant.int8;
    final AsrModelStore store = await AsrModelStore.open(language);
    await for (final ModelDownloadEvent e in store.download(variant)) {
      final String pct = e.totalBytes == 0
          ? '--'
          : '${(e.receivedBytes / e.totalBytes * 100).toStringAsFixed(1)}%';
      stderr.write('\r${e.fileName.padRight(32)} $pct   ');
    }
    stderr.writeln('\n完成');
    return 0;
  }
}

class _ModelsExportCommand extends Command<int> {
  _ModelsExportCommand() {
    argParser.addOption('output', abbr: 'o', help: '写到文件；省略写 stdout');
  }

  @override
  String get name => 'export-manifest';

  @override
  String get description => '把当前注册表导成 JSON 清单（自带模型的模板）。';

  @override
  Future<int> run() async {
    final ({AsrModelRegistry registry, Directory? dataRoot}) ctx =
        await _context(this);
    final String text =
        '${const JsonEncoder.withIndent('  ').convert(ctx.registry.toJson())}\n';
    final String? out = argResults!['output'] as String?;
    if (out == null) {
      stdout.write(text);
    } else {
      await File(out).writeAsString(text);
      stderr.writeln('写入 $out');
    }
    return 0;
  }
}

Future<Directory> _packDir(AsrModelPack pack) async {
  final Directory root = await asrSupportRootDirectory();
  return Directory('${root.path}${Platform.pathSeparator}asr_models'
      '${Platform.pathSeparator}${pack.id}');
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

// --------------------------------------------------------------------- serve

class ServeCommand extends Command<int> {
  ServeCommand() {
    argParser
      ..addOption('host', defaultsTo: '127.0.0.1', help: '监听地址')
      ..addOption('port', abbr: 'p', defaultsTo: '8642', help: '监听端口')
      ..addOption('token',
          help: '接口令牌（请求带 Authorization: Bearer <token>）；省略则不鉴权')
      ..addFlag('cpu', help: '强制 CPU', negatable: false)
      ..addOption('concurrency',
          defaultsTo: '1',
          help: '同时跑几个转录任务。**默认 1**：GPU 会话并发建很容易把显存撑爆');
  }

  @override
  String get name => 'serve';

  @override
  String get description => '起 HTTP 服务端（自带一个最小网页界面）。';

  @override
  Future<int> run() async {
    final ({AsrModelRegistry registry, Directory? dataRoot}) ctx =
        await _context(this);
    final int port = int.parse(argResults!['port'] as String);
    final String? token = argResults!['token'] as String?;
    if (token == null && (argResults!['host'] as String) != '127.0.0.1') {
      // 绑到非回环地址却不设令牌，等于把本机的 GPU 和磁盘开放给整个网段。
      stderr.writeln(
        '警告：监听在 ${argResults!["host"]} 却没设 --token，任何人都能提交任务。',
      );
    }
    final AsrServer server = AsrServer(
      runner: TranscribeRunner(
        registry: ctx.registry,
        dataRoot: ctx.dataRoot,
        forceCpu: argResults!['cpu'] as bool,
      ),
      registry: ctx.registry,
      token: token,
      concurrency: int.parse(argResults!['concurrency'] as String),
    );
    final Uri uri = await server.start(
      host: argResults!['host'] as String,
      port: port,
    );
    stderr.writeln('asr 服务端已启动：$uri');
    stderr.writeln('界面：$uri　　API：${uri}v1/transcribe');
    await ProcessSignal.sigint.watch().first;
    stderr.writeln('\n收到 SIGINT，停止服务');
    await server.stop();
    return 0;
  }
}
