/// The spoken part of a subtitle, used only for matching against ASR text.
///
/// Japanese broadcast captions put speaker names and sound descriptions in
/// fullwidth parentheses at the start of a line. Those words are not spoken.
/// Keep parentheticals inside dialogue and ASCII parentheses: they can be part
/// of the sentence. Callers must retain the original cue text for output.
String subtitleSpeechText(String text) {
  final plain = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_lineBreakTag, '\n')
      .replaceAll(_markup, '')
      .replaceAll('&nbsp;', ' ');
  final lines = <String>[];
  for (var line in plain.split('\n')) {
    line = line.trim();
    if (_musicCaption.hasMatch(line)) continue;
    while (true) {
      final label = _leadingLabel.firstMatch(line);
      if (label == null) break;
      line = line.substring(label.end).trimLeft();
    }
    if (line.isNotEmpty && !_musicOnly.hasMatch(line)) lines.add(line);
  }
  return lines.join('\n');
}

final _lineBreakTag = RegExp(r'<br\s*/?>', caseSensitive: false);
final _markup = RegExp(r'<[^<>]*>|\{\\[^{}]*\}');
final _leadingLabel = RegExp(r'^（[^（）\n]+）');
final _musicOnly = RegExp(r'^[\s♪♫♬♩~～〜…・.]*$');
// A note prefix is common for music descriptions. Do not discard sung words
// merely because they are surrounded by music-note symbols.
final _musicCaption = RegExp(
  r'^[\s♪♫♬♩~～〜]*（(?:音楽|BGM|ＢＧＭ|前奏|間奏|後奏)）[\s♪♫♬♩~～〜]*$',
  caseSensitive: false,
);
