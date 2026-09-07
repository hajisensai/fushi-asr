import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:asr_align/asr_align.dart';
import 'package:test/test.dart';

List<int> makeEpub({String? opf, Map<String, String>? chapters}) {
  final files = <String, String>{
    'META-INF/container.xml':
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    'OPS/book.opf': opf ??
        '<package><metadata><title>Test book</title><language>ja</language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b%20one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="b"/><itemref idref="a"/></spine></package>',
    ...?chapters,
    if (chapters == null)
      'OPS/a.xhtml': '<html><body><p>第二章の本文です。</p></body></html>',
    if (chapters == null)
      'OPS/b one.xhtml':
          '<html><body><script>BAD</script><p><ruby>漢字<rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby>を読む。</p><p hidden>HIDDEN</p></body></html>',
  };
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.add(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  test(
      'uses OPF spine order, encoded hrefs, metadata and ruby base/reading offsets',
      () {
    final book = parseEpubBytes(makeEpub());
    expect(book.title, 'Test book');
    expect(book.language, 'ja');
    expect(
        book.sections.map((s) => s.href), ['OPS/b one.xhtml', 'OPS/a.xhtml']);
    final section = book.sections.first;
    expect(section.text, contains('漢字を読む。'));
    expect(section.text, isNot(contains('かんじ')));
    expect(section.text, isNot(contains('BAD')));
    expect(section.text, isNot(contains('HIDDEN')));
    final ruby = section.rubies.single;
    expect(section.text.substring(ruby.start, ruby.end), '漢字');
    expect(ruby.reading, 'かんじ');
  });
  test('rejects missing chapters and escaping archive paths', () {
    expect(
        () => parseEpubBytes(
            makeEpub(chapters: {'OPS/a.xhtml': '<p>only one</p>'})),
        throwsFormatException);
    expect(
        () => parseEpubBytes(makeEpub(chapters: {'../outside.xhtml': 'bad'})),
        throwsFormatException);
  });
  test('rejects external spine URLs and empty spine', () {
    expect(
        () => parseEpubBytes(makeEpub(
            opf:
                '<package><manifest><item id="x" href="https://example.com/book.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="x"/></spine></package>')),
        throwsFormatException);
    expect(() => parseEpubBytes(makeEpub(opf: '<package><spine/></package>')),
        throwsFormatException);
  });
  test('rejects oversized decompressed chapter before reading content', () {
    expect(
        () => parseEpubBytes(makeEpub(
            chapters: {'OPS/b one.xhtml': 'x' * (4 * 1024 * 1024 + 1)})),
        throwsFormatException);
  });
}
