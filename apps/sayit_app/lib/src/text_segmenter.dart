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

/// 一个分句结果。
///
/// 注意：`startOffset` / `endOffset` 是相对于 [`TextSegmenter.normalize`] 之后文本的
/// UTF-16 偏移（不是 rune 下标），并且已经按 trim 结果校正过，与 `text` 严格对齐。
class Sentence {
  final int index;
  final String text;
  final int startOffset;
  final int endOffset;

  const Sentence({
    required this.index,
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });

  @override
  String toString() =>
      'Sentence($index, "$text", offsets=$startOffset-$endOffset)';
}

class TextSegmenter {
  static const _defaultEndPuncts = '。！？；,.!?;:';

  /// 句末标点集合（可配置）。
  ///
  /// 注：曾经这里还维护一张「标点 → 停顿毫秒」的表（`breakTimes`），
  /// 用来在句间插入静音。edge_tts 的输出是固定编码的 MP3，
  /// 想往里插静音必须解码重编码，本项目没有 MP3 编码器，
  /// 所以句间停顿功能已整体移除（见 main.dart 顶部注释）。
  /// 停顿现在完全交给 TTS 自己处理。
  final String endPuncts;

  const TextSegmenter({this.endPuncts = _defaultEndPuncts});

  /// 归一化：剥掉强调标记 `[!...!]`，只保留内部文字。
  ///
  /// 之前 [`preprocessText`] 是恒等函数、强调标记又被"占位符→还原"空转一圈，
  /// 结果 `[!重要!]` 被原样送进 TTS，语音里会把方括号和感叹号念出来。
  static String normalize(String text) =>
      text.replaceAllMapped(RegExp(r'\[!(.+?)!\]'), (m) => m.group(1)!);

  /// 送进 TTS 之前的文本预处理。
  static String preprocessText(String text) => normalize(text).trim();

  static bool _isDigit(String? s) {
    if (s == null || s.isEmpty) return false;
    final c = s.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39;
  }

  /// 判断第 `i` 个 rune 是否应该断句。
  ///
  /// 处理四类误判：
  /// - 连续标点（`！！`、`...`）→ 只在最后一个断开，避免切出 `！` `？` 这类碎片句
  /// - 小数点 / 千分位 / 时间冒号（`3.14`、`1,000`、`12:30`）→ 数字之间的标点不断
  /// - URL 里的 `:`（`http://`）→ 后面紧跟 `/` 时不断
  /// - 域名 / 英文缩写里的 `.`（`a.com`、`Mr.Smith`）→ 两侧都是字母时不断
  bool _isBreak(String text, List<int> runes, int i, Set<int> punctSet) {
    final code = runes[i];
    final ch = String.fromCharCode(code);

    // 连续标点：让最后一个标点来收尾
    if (i + 1 < runes.length && punctSet.contains(runes[i + 1])) {
      return false;
    }

    if (ch == '.' || ch == ',' || ch == ':') {
      final prev = i > 0 ? String.fromCharCode(runes[i - 1]) : null;
      final next = i + 1 < runes.length ? String.fromCharCode(runes[i + 1]) : null;
      // 数字之间的 . , : 属于数字本身
      if (_isDigit(prev) && _isDigit(next)) return false;
      // http:// 、https://
      if (ch == ':' && next == '/') return false;
      // 域名 / 缩写（a.com、Mr.Smith）：两侧都是字母且中间没空格
      if (ch == '.' && _isAsciiLetter(prev) && _isAsciiLetter(next)) {
        return false;
      }
    }

    return true;
  }

  static bool _isAsciiLetter(String? s) {
    if (s == null || s.isEmpty) return false;
    final c = s.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  }

  /// 把 [input] 切成句子。
  ///
  /// 遍历以 **rune（code point）** 为单位进行，同时维护对应的 UTF-16 偏移。
  /// 以前的实现用 UTF-16 下标 `i` 去索引 `runes.elementAt(i)`，两套下标体系混用，
  /// 遇到 emoji 等 BMP 外字符时会错位、切断代理对，甚至抛 RangeError。
  List<Sentence> segment(String input) {
    final text = normalize(input);
    final runes = text.runes.toList();
    final punctSet = endPuncts.runes.toSet();

    final sentences = <Sentence>[];
    var index = 0;
    var segStartCu = 0; // 当前句起点（UTF-16 偏移）
    var cu = 0; // 当前 rune 结束处的 UTF-16 偏移

    void flush(int endCu) {
      if (endCu <= segStartCu) return;
      final raw = text.substring(segStartCu, endCu);
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return;
      // trim 会吃掉前导空白，偏移要跟着挪，否则 startOffset 与 text 对不上
      final lead = raw.length - raw.trimLeft().length;
      final start = segStartCu + lead;
      sentences.add(Sentence(
        index: index++,
        text: trimmed,
        startOffset: start,
        endOffset: start + trimmed.length,
      ));
    }

    for (var i = 0; i < runes.length; i++) {
      final code = runes[i];
      // 一个 rune 占 1 或 2 个 UTF-16 code unit
      cu += (code > 0xFFFF) ? 2 : 1;

      if (punctSet.contains(code) && _isBreak(text, runes, i, punctSet)) {
        flush(cu);
        segStartCu = cu;
      }
    }

    // 末尾残余（最后一段没有句末标点的情况）
    if (segStartCu < text.length) {
      flush(text.length);
    }

    return sentences;
  }
}
