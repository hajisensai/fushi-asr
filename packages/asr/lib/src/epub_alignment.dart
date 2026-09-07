import 'dart:io';
import 'cancellation.dart';
import 'package:asr_align/asr_align.dart';
import 'subtitle_format.dart';
import 'transcribe_runner.dart';
export 'package:asr_align/asr_align.dart'
    show EpubBook, readEpubBook, maxEpubBytes;

class BookAlignedSubtitles {
  const BookAlignedSubtitles(this.text, this.cueCount, this.stats);
  final String text;
  final int cueCount;
  final Map<String, Object?> stats;
}

Future<BookAlignedSubtitles> alignTranscriptionWithBook(
        EpubBook book, TranscribeOutcome original, SubtitleFormat format,
        {TranscribeCancellation? cancellation}) =>
    cancellableCompute(_alignmentTask(book, original, format), cancellation);

Future<EpubBook> readCancellableEpubBook(
        String path, TranscribeCancellation token) =>
    cancellableCompute(_bookTask(path), token);

EpubBook Function() _bookTask(String path) => () {
      final file = File(path);
      if (file.lengthSync() > maxEpubBytes) {
        throw const FormatException('EPUB 超过 64 MiB 上限');
      }
      return parseEpubBytes(file.readAsBytesSync());
    };

BookAlignedSubtitles Function() _alignmentTask(
        EpubBook book, TranscribeOutcome original, SubtitleFormat format) =>
    () {
      final watch = Stopwatch()..start();
      final cues = [
        for (var i = 0; i < original.cues.length; i++)
          AlignCue()
            ..bookKey = ''
            ..chapterHref = ''
            ..sentenceIndex = i
            ..textFragmentId = ''
            ..audioFileIndex = 0
            ..text = original.cues[i].text
            ..startMs = original.cues[i].startMs
            ..endMs = original.cues[i].endMs
            ..tokenTiming =
                original.tokenTimings?.length == original.cues.length
                    ? original.tokenTimings![i]
                    : null
      ];
      final match = EpubCueMatcher.match(sections: book.sections, cues: cues);
      final resegmented = const CueSentenceResegmenter()
          .resegment(sections: book.sections, cues: cues, result: match);
      replaceMatchedCueTextWithBookText(
          sections: book.sections,
          cues: resegmented.cues,
          result: resegmented.result);
      final output = [
        for (var i = 0; i < resegmented.cues.length; i++)
          SubtitleCue(
              index: i + 1,
              startMs: resegmented.cues[i].startMs,
              endMs: resegmented.cues[i].endMs,
              text: resegmented.cues[i].text)
      ];
      watch.stop();
      return BookAlignedSubtitles(
          renderSubtitles(output, format), output.length, {
        'bookTitle': book.title,
        'bookLanguage': book.language,
        'sections': book.sections.length,
        'inputCues': match.totalCues,
        'matchedCues': match.matchedCues,
        'unmatchedCues': match.totalCues - match.matchedCues,
        'matchRate': match.matchRate,
        'elapsedMs': watch.elapsedMilliseconds,
        'boundariesAdded': resegmented.stats.boundariesAdded,
        'boundariesRemoved': resegmented.stats.boundariesRemoved,
        'timingMode': original.tokenTimings == null
            ? 'segment-preserved'
            : 'token-resegmented',
        'warnings': [
          if (match.matchRate < 0.6) '正文匹配率较低，请检查书籍版本、语言或音频范围；未匹配部分保留原始转录。',
          if (original.tokenTimings == null) '此方案没有逐词时间戳，保留原始片段时间，不按字数伪造句界时间。',
        ],
      });
    };
