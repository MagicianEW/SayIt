import 'package:flutter_test/flutter_test.dart';
import 'package:sayit_app/src/text_segmenter.dart';

/// 分句逻辑的回归测试。
///
/// 覆盖 `_isBreak()` 里那些"看起来只在极端输入才触发"的规则：
/// 连续标点、小数点、千分位、URL 冒号、域名点、emoji 偏移。
/// 这些点以前全是 bug，回归成本很低，所以钉在这里。
void main() {
  List<String> texts(String input) =>
      const TextSegmenter().segment(input).map((s) => s.text).toList();

  group('TextSegmenter.segment', () {
    test('中文句号切分', () {
      expect(texts('你好。世界。'), ['你好。', '世界。']);
    });

    test('连续标点只在最后一个断开', () {
      // 以前会把 `？！` 切成两句，产生 `真的吗？` + `！` 这种碎片
      expect(texts('真的吗？！好吧。'), ['真的吗？！', '好吧。']);
    });

    test('数字之间的小数点不断句', () {
      expect(texts('圆周率是 3.14。'), ['圆周率是 3.14。']);
    });

    test('千分位逗号不断句', () {
      expect(texts('一共 1,000 元。'), ['一共 1,000 元。']);
    });

    test('URL 里的冒号不断句', () {
      expect(texts('见 https://example.com 吧。'), ['见 https://example.com 吧。']);
    });

    test('域名里的点不断句，句尾的点要断', () {
      expect(texts('访问 a.com 看看。'), ['访问 a.com 看看。']);
      expect(texts('Mr.Smith is here. Thanks.'),
          ['Mr.Smith is here.', 'Thanks.']);
    });

    test('emoji 不崩溃且不切断代理对', () {
      expect(texts('你好😀。世界。'), ['你好😀。', '世界。']);
    });

    test('末尾没有句末标点时也算一句', () {
      expect(texts('前面。后面没有标点'), ['前面。', '后面没有标点']);
    });

    test('强调标记 [!...!] 被剥离', () {
      expect(texts('这是[!重要!]的。'), ['这是重要的。']);
    });
  });

  group('TextSegmenter 偏移', () {
    test('startOffset/endOffset 与 normalize 后的文本严格对齐', () {
      const src = '你好😀。世界。';
      final normalized = TextSegmenter.preprocessText(src);
      for (final s in const TextSegmenter().segment(src)) {
        expect(normalized.substring(s.startOffset, s.endOffset), s.text,
            reason: '第 ${s.index} 句偏移对不上');
      }
    });
  });

  group('Sentence', () {
    test('不再包含句间停顿字段', () {
      // 句间停顿功能已移除：edge_tts 输出固定 MP3，无法在不解码重编码的前提下插静音。
      expect(const TextSegmenter().segment('你好。').first.toString(),
          isNot(contains('break=')));
    });
  });
}
