/// README 多语言守卫。
///
/// 语言集合不是在这里硬编码的，而是从网页界面的 `web/src/lib/i18n.ts` 的 `LANGS`
/// 读出来——app、官网、网页界面已经是同一批 17 种语言，README 再单开一份清单，
/// 迟早会和它们分叉（加了一门语言只改界面、README 悄悄少一种，没人会发现）。
/// 让真相源只有一个，加语言时这个测试直接报出缺哪个文件。
///
/// 除「文件在不在」之外还盯两件真会出错的事：
///  - **命令必须逐字一致**。翻译时最容易顺手把 `-l en` 改成 `-l de`、把路径本地化，
///    读者照着敲就是错的。代码块里的注释允许翻译，命令本身不许动。
///  - **导航行必须逐字节一致**。它是 17 个文件互相跳转的唯一入口，少一个链接就是
///    死路；相对深度还不同（根目录一份、docs/readme/ 一份），手写必错。
library;

import 'dart:io';

import 'package:test/test.dart';

/// 仓库根：从当前包往上找，认「同时有 README.md 和 packages/」的那一层。
Directory repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/README.md').existsSync() &&
        Directory('${dir.path}/packages').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('找不到仓库根（从 ${Directory.current.path} 往上）');
}

/// 从网页界面 i18n 里读语言集合（码 + 自称），顺序即菜单顺序。
List<(String, String)> webUiLangs(Directory root) {
  final File file =
      File('${root.path}/packages/asr_server/web/src/lib/i18n.ts');
  final String source = file.readAsStringSync();
  final int start = source.indexOf('export const LANGS');
  if (start < 0) throw StateError('${file.path} 里没有 export const LANGS');
  final int open = source.indexOf('= [', start);
  final int close = source.indexOf('];', open);
  final String body = source.substring(open, close);
  final RegExp entry = RegExp(r"\['([^']+)',\s*'([^']+)'\]");
  final List<(String, String)> langs = entry
      .allMatches(body)
      .map((RegExpMatch m) => (m.group(1)!, m.group(2)!))
      .toList();
  if (langs.length < 2) throw StateError('LANGS 解析出 ${langs.length} 项，不合理');
  return langs;
}

const String kNavComment =
    '<!-- Language nav: order matches LANGS in the web UI i18n; guarded by readme_i18n_test.dart -->';

/// 某语言 README 该有的导航行。`en` 在仓库根，其余在 `docs/readme/`。
String navLine(List<(String, String)> langs, String current) {
  final List<String> parts = <String>[];
  for (final (String code, String name) in langs) {
    if (code == current) {
      parts.add('**$name**');
    } else if (code == 'en') {
      parts.add('[$name](${current == 'en' ? 'README.md' : '../../README.md'})');
    } else {
      final String href = current == 'en'
          ? 'docs/readme/README.$code.md'
          : 'README.$code.md';
      parts.add('[$name]($href)');
    }
  }
  return parts.join(' · ');
}

/// 语言码 → 文件路径。
String readmePath(Directory root, String code) => code == 'en'
    ? '${root.path}/README.md'
    : '${root.path}/docs/readme/README.$code.md';

/// 一个围栏代码块：语言标注 + 去掉注释与空行后的正文。
typedef CodeBlock = (String fence, String body);

/// 抽出所有围栏代码块。注释按块语言剥掉（bash 的 `#`、js 的 `//`）——注释允许翻译，
/// 命令不允许。剥完再比，才是「命令一致」而不是「整块一致」。
List<CodeBlock> codeBlocks(String markdown) {
  final List<CodeBlock> blocks = <CodeBlock>[];
  final List<String> lines = markdown.split('\n');
  String? fence;
  List<String>? current;
  for (final String line in lines) {
    if (line.startsWith('```')) {
      if (current == null) {
        fence = line.substring(3).trim();
        current = <String>[];
      } else {
        blocks.add((fence!, current.join('\n')));
        current = null;
        fence = null;
      }
      continue;
    }
    if (current == null) continue;
    final String stripped = stripComment(line, fence!);
    if (stripped.trim().isEmpty) continue;
    current.add(stripped.trimRight());
  }
  if (current != null) throw StateError('代码块没有闭合');
  return blocks;
}

/// 去掉一行里的注释部分。行内 `#` 只有在前面有空白或行首时才算注释起点，
/// 免得把 URL 里的片段或 shell 变量误当注释。
String stripComment(String line, String fence) {
  if (fence == 'bash' || fence == 'sh') {
    final int hash = line.startsWith('#') ? 0 : line.indexOf(' #');
    return hash < 0 ? line : line.substring(0, hash);
  }
  if (fence == 'js' || fence == 'ts') {
    // 只剥整行注释：`https://` 里也有 `//`，按位置切会把 URL 砍掉。
    return line.trimLeft().startsWith('//') ? '' : line;
  }
  return line;
}

/// 标题层级序列（跳过代码块——bash 注释以 `#` 开头，会被当成标题）。
List<int> headingLevels(String markdown) {
  final List<int> levels = <int>[];
  bool inFence = false;
  for (final String line in markdown.split('\n')) {
    if (line.startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final RegExpMatch? m = RegExp(r'^(#{1,6}) ').firstMatch(line);
    if (m != null) levels.add(m.group(1)!.length);
  }
  return levels;
}

void main() {
  final Directory root = repoRoot();
  final List<(String, String)> langs = webUiLangs(root);
  final String english = File(readmePath(root, 'en')).readAsStringSync();
  final List<CodeBlock> englishBlocks = codeBlocks(english);
  final List<int> englishHeadings = headingLevels(english);

  test('英文 README 是仓库根的那一份，且有实打实的内容可比', () {
    expect(langs.map((l) => l.$1), contains('en'));
    expect(englishBlocks.length, greaterThanOrEqualTo(5));
    expect(englishHeadings.first, 1);
  });

  for (final (String code, String name) in langs) {
    group('README.$code（$name）', () {
      final String path = readmePath(root, code);
      final File file = File(path);

      test('文件存在', () {
        expect(file.existsSync(), isTrue,
            reason: '网页界面 i18n 里有 $code，README 却没有：缺 $path');
      });

      test('导航行逐字节一致', () {
        final List<String> lines = file.readAsStringSync().split('\n');
        expect(lines[0], kNavComment);
        expect(lines[1], navLine(langs, code));
      });

      test('代码块里的命令与英文版一致', () {
        final List<CodeBlock> blocks = codeBlocks(file.readAsStringSync());
        expect(blocks.length, englishBlocks.length,
            reason: '代码块数量对不上，八成是漏译或多写了一段');
        for (int i = 0; i < blocks.length; i++) {
          expect(blocks[i].$1, englishBlocks[i].$1, reason: '第 $i 块的语言标注不同');
          expect(blocks[i].$2, englishBlocks[i].$2,
              reason: '第 $i 块的命令被改动了——注释可以翻译，命令必须逐字保留');
        }
      });

      test('章节结构与英文版一致', () {
        expect(headingLevels(file.readAsStringSync()), englishHeadings);
      });

      test('编码与换行：UTF-8 无 BOM、LF', () {
        final List<int> bytes = file.readAsBytesSync();
        expect(bytes.take(3).toList(), isNot(<int>[0xEF, 0xBB, 0xBF]),
            reason: '不要带 BOM');
        expect(bytes.contains(0x0D), isFalse, reason: '不要 CRLF');
      });

      test('文档相对链接按所在目录深度写对', () {
        final String text = file.readAsStringSync();
        final Map<String, String> expected = code == 'en'
            ? <String, String>{
                'docs/MACOS_COREML.md': '(docs/MACOS_COREML.md)',
                'docs/MACOS_DEVELOPMENT.md': '(docs/MACOS_DEVELOPMENT.md)',
                'docs/PLAN.md': '(docs/PLAN.md)',
                'LICENSE': '(LICENSE)',
              }
            : <String, String>{
                'docs/MACOS_COREML.md': '(../MACOS_COREML.md)',
                'docs/MACOS_DEVELOPMENT.md': '(../MACOS_DEVELOPMENT.md)',
                'docs/PLAN.md': '(../PLAN.md)',
                'LICENSE': '(../../LICENSE)',
              };
        for (final MapEntry<String, String> e in expected.entries) {
          expect(text, contains(e.value), reason: '${e.key} 的相对链接不对');
        }
      });

      test('导航里指向的每个文件都真的在', () {
        final String text = file.readAsStringSync().split('\n')[1];
        final Iterable<RegExpMatch> links =
            RegExp(r'\]\(([^)]+)\)').allMatches(text);
        final String dir = code == 'en' ? root.path : '${root.path}/docs/readme';
        for (final RegExpMatch m in links) {
          final String target = '$dir/${m.group(1)!}';
          expect(File(target).existsSync(), isTrue, reason: '死链：$target');
        }
      });
    });
  }
}
