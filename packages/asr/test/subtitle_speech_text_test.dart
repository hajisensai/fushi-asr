import 'package:fushi_asr/src/subtitle_speech_text.dart';
import 'package:test/test.dart';

void main() {
  group('subtitleSpeechText', () {
    test('removes broadcast speaker labels independently on each line', () {
      expect(
        subtitleSpeechText('（阿近）どうした！？\n（鵯州）境界侵度プラス一・０二。'),
        'どうした！？\n境界侵度プラス一・０二。',
      );
    });

    test('accepts leading spaces, repeated labels and label-only lines', () {
      expect(
        subtitleSpeechText(' \t　（竜ノ介）\r\n（声）（竜ノ介） な…　何が起こってるんです？'),
        'な…　何が起こってるんです？',
      );
    });

    test('sound descriptions alone cannot become spoken anchors', () {
      for (final text in ['（アラーム）', '（カラスの鳴き声）', '（うなり声）']) {
        expect(subtitleSpeechText(text), isEmpty);
      }
    });

    test('keeps parentheticals within dialogue', () {
      expect(
        subtitleSpeechText('この説明（たとえば今の話）は大切です。'),
        'この説明（たとえば今の話）は大切です。',
      );
    });

    test('does not treat ordinary ASCII parentheses as broadcast labels', () {
      expect(subtitleSpeechText('(For example) this is spoken.'),
          '(For example) this is spoken.');
    });

    test('recognizes annotations behind subtitle formatting', () {
      expect(
        subtitleSpeechText('<i>&nbsp;（剣八）なんだこりゃ？</i><br />'
            r'{\an8}（日番谷）どういうこった。'),
        'なんだこりゃ？\nどういうこった。',
      );
    });

    test('removes music-only captions but keeps lyrics with note symbols', () {
      for (final text in ['♪～', '♬　〜', '♪（音楽）～', '♫（BGM）']) {
        expect(subtitleSpeechText(text), isEmpty);
      }
      expect(subtitleSpeechText('♪君と歩いていく♪'), '♪君と歩いていく♪');
      expect(subtitleSpeechText('♪（君がいる）♪'), '♪（君がいる）♪');
    });

    test('retains malformed parentheses instead of swallowing speech', () {
      expect(subtitleSpeechText('（閉じていない台詞'), '（閉じていない台詞');
      expect(subtitleSpeechText('（）台詞'), '（）台詞');
    });
  });
}
