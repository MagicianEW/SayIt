// Copyright (C) 2026 SayIt Contributors
//
// This file is part of SayIt.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
  static const _defaultEndPuncts = '。！？；,.!?;:';

  static const Map<String, int> _defaultBreakTimes = {
    '。': 500,
    '！': 500,
    '？': 500,
    '；': 300,
    ',': 200,
    '.': 200,
    '!': 500,
    '?': 500,
    ';': 200,
    ':': 200,
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
