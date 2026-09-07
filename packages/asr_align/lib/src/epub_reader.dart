import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'epub_srt_matcher.dart';

class EpubBook {
  const EpubBook(
      {required this.title, required this.language, required this.sections});
  final String title;
  final String language;
  final List<EpubSection> sections;
}

const maxEpubBytes = 64 * 1024 * 1024;

Future<EpubBook> readEpubBook(String path) => Isolate.run(() {
      final file = File(path);
      if (file.lengthSync() > maxEpubBytes) {
        throw const FormatException('EPUB 超过 64 MiB 上限');
      }
      return parseEpubBytes(file.readAsBytesSync());
    });

/// Read only the package and spine XHTML; never extract to disk or fetch URLs.
/// ZIP headers are inspected before any decompression, including symlinks.
EpubBook parseEpubBytes(List<int> bytes) {
  if (bytes.length > maxEpubBytes) {
    throw const FormatException('EPUB 超过 64 MiB 上限');
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.length > 10000) {
    throw const FormatException('EPUB 条目过多');
  }
  final files = <String, ZipFileHeader>{};
  for (final entry in directory.fileHeaders) {
    final name = _safePath(entry.filename);
    if (files.containsKey(name)) throw const FormatException('EPUB 有重复条目');
    files[name] = entry;
  }
  int total = 0;
  String read(String name) {
    final entry = files[name];
    if (entry == null || entry.file == null) {
      throw FormatException('EPUB 缺少 $name');
    }
    if (entry.generalPurposeBitFlag & 1 != 0 || entry.file!.flags & 1 != 0) {
      throw const FormatException('不支持加密 EPUB');
    }
    if ((entry.externalFileAttributes >> 16) & 0xf000 == 0xa000) {
      throw const FormatException('EPUB 正文不可为符号链接');
    }
    if (![0, 8].contains(entry.compressionMethod)) {
      throw const FormatException('不支持此 EPUB 压缩方式');
    }
    if (entry.uncompressedSize > 4 * 1024 * 1024) {
      throw const FormatException('EPUB 单章过大');
    }
    final output = _BoundedOutput(4 * 1024 * 1024);
    entry.file!.decompress(output);
    final data = output.getBytes();
    total += data.length;
    if (total > 32 * 1024 * 1024) {
      throw const FormatException('EPUB 正文超过 32 MiB 上限');
    }
    if (data.length != entry.uncompressedSize ||
        getCrc32(data) != entry.crc32) {
      throw const FormatException('EPUB 数据损坏（长度或 CRC 不符）');
    }
    return utf8.decode(data);
  }

  final container = XmlDocument.parse(read('META-INF/container.xml'));
  final roots = container.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'rootfile');
  if (roots.isEmpty) throw const FormatException('EPUB 缺少 OPF 入口');
  final opfPath = _safePath(roots.first.getAttribute('full-path') ?? '');
  final opf = XmlDocument.parse(read(opfPath));
  Iterable<XmlElement> elements(String tag) =>
      opf.descendants.whereType<XmlElement>().where((e) => e.name.local == tag);
  String metadata(String tag) =>
      elements(tag).isEmpty ? '' : elements(tag).first.innerText.trim();
  final manifest = <String, XmlElement>{
    for (final item in elements('item'))
      if (item.getAttribute('id') != null) item.getAttribute('id')!: item
  };
  final sections = <EpubSection>[];
  final seen = <String>{};
  for (final ref in elements('itemref')) {
    if (ref.getAttribute('linear') == 'no') continue;
    final item = manifest[ref.getAttribute('idref')];
    if (item == null) throw const FormatException('EPUB spine 引用了不存在的章节');
    if ((item.getAttribute('properties') ?? '').split(' ').contains('nav')) {
      continue;
    }
    if (!['application/xhtml+xml', 'text/html']
        .contains(item.getAttribute('media-type'))) {
      continue;
    }
    final uri = Uri.parse(item.getAttribute('href') ?? '');
    if (uri.hasScheme || uri.hasAuthority || uri.path.isEmpty) {
      throw const FormatException('EPUB 正文必须是内置文件');
    }
    final href = _safePath(
        p.posix.join(p.posix.dirname(opfPath), Uri.decodeComponent(uri.path)));
    if (!seen.add(href)) continue;
    final section =
        sectionFromHtml(read(href), index: sections.length, href: href);
    if (section.text.trim().isNotEmpty) sections.add(section);
  }
  if (sections.isEmpty) {
    throw const FormatException('EPUB 没有可读取的正文（扫描版或无有效 spine）');
  }
  return EpubBook(
      title: metadata('title'),
      language: metadata('language'),
      sections: sections);
}

String _safePath(String value) {
  if (value.isEmpty ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      p.posix.isAbsolute(value)) {
    throw const FormatException('EPUB 内部路径非法');
  }
  final path = p.posix.normalize(value);
  if (path == '..' || path.startsWith('../') || path == '.') {
    throw const FormatException('EPUB 路径越界');
  }
  return path;
}

EpubSection sectionFromHtml(String source,
    {required int index, required String href}) {
  final document = html.parse(source);
  final text = StringBuffer();
  final rubies = <EpubRubySpan>[];
  const blocks = {
    'p',
    'div',
    'section',
    'article',
    'h1',
    'h2',
    'h3',
    'h4',
    'li',
    'blockquote',
    'br'
  };
  void walk(dom.Node node) {
    if (node is dom.Text) {
      text.write(node.data);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if ({'rt', 'rp', 'script', 'style', 'noscript', 'nav'}.contains(tag) ||
        node.attributes.containsKey('hidden') ||
        node.attributes['aria-hidden'] == 'true') {
      return;
    }
    if (blocks.contains(tag)) text.write('\n');
    final start = text.length;
    for (final child in node.nodes) {
      walk(child);
    }
    if (tag == 'ruby' && text.length > start) {
      final reading =
          node.querySelectorAll('rt').map((e) => e.text).join().trim();
      if (reading.isNotEmpty) {
        rubies.add(
            EpubRubySpan(start: start, end: text.length, reading: reading));
      }
    }
    if (blocks.contains(tag)) text.write('\n');
  }

  if (document.body != null) walk(document.body!);
  return EpubSection(
      index: index, href: href, text: text.toString(), rubies: rubies);
}

class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit);
  final int limit;
  void check(int count) {
    if (count < 0 || length + count > limit) {
      throw const FormatException('EPUB 解压内容超过上限');
    }
  }

  @override
  void writeByte(int value) {
    check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    check(count);
    super.writeBackReference(distance, count);
  }
}
