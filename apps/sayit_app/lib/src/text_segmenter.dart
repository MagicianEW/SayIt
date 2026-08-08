class Sentence {
  final int index;
  final String text;
  final int breakTimeMs;
  final int startOffset;
  final int endOffset;

  const Sentence({
    required this.index,
    required this.text,
    required this.breakTimeMs,
    required this.startOffset,
    required this.endOffset,
  });

  @override
  String toString() =>
      'Sentence($index, "$text", break=${breakTimeMs}ms, offsets=$startOffset-$endOffset)';
}

class TextSegmenter {
  static const _defaultEndPuncts = '。！？；';

  static const Map<String, int> _defaultBreakTimes = {
    '。': 500,
    '！': 500,
    '？': 500,
    '；': 300,
  };

  final String endPuncts;
  final Map<String, int> breakTimes;

  const TextSegmenter({
    this.endPuncts = _defaultEndPuncts,
    Map<String, int>? breakTimes,
  }) : breakTimes = breakTimes ?? _defaultBreakTimes;

  List<Sentence> segment(String text) {
    final sentences = <Sentence>[];
    final punctSet = endPuncts.runes.toSet();

    int sentenceStart = 0;
    int sentenceIndex = 0;
    int i = 0;

    while (i < text.length) {
      final code = text.runes.elementAt(i);

      if (punctSet.contains(code)) {
        final char = String.fromCharCode(code);
        final breakTime = breakTimes[char] ?? 300;
        final sentenceText = text.substring(sentenceStart, i + 1).trim();
        if (sentenceText.isNotEmpty) {
          sentences.add(Sentence(
            index: sentenceIndex++,
            text: sentenceText,
            breakTimeMs: breakTime,
            startOffset: sentenceStart,
            endOffset: i + 1,
          ));
        }
        sentenceStart = i + 1;
      }

      i++;
    }

    final remaining = text.substring(sentenceStart).trim();
    if (remaining.isNotEmpty) {
      sentences.add(Sentence(
        index: sentenceIndex,
        text: remaining,
        breakTimeMs: 0,
        startOffset: sentenceStart,
        endOffset: text.length,
      ));
    }

    return sentences;
  }

  static String preprocessText(String text) {
    return text;
  }
}
