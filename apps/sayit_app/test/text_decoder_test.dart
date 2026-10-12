import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sayit_app/src/text_decoder.dart';

/// 真实 GB18030 字节，由 Python `s.encode('gb18030')` 生成。
/// 纯中文 + ASCII 段落在 GBK 与 GB18030 的两字节区完全一致。
final _gb18030Chinese = Uint8List.fromList([
  0xD6, 0xD0, 0xCE, 0xC4, // 中文
  0xB2, 0xE2, 0xCA, 0xD4, // 测试
  0xC4, 0xDA, 0xC8, 0xDD, // 内容
  0xA1, 0xA3, // 。
  0x41, 0x42, 0x43, 0x20, // ABC
  0x31, 0x32, 0x33, // 123
]);

/// 𠀀 (U+20000) 在 GB18030 里是四字节序列 95 32 82 36，
/// **GBK 解不了**（GBK 没有四字节区）。这一条能区分
/// "真 GB18030 codec" 和 "拿 GBK 冒充 GB18030"。
final _gb18030FourByte = Uint8List.fromList([0x95, 0x32, 0x82, 0x36]);

void main() {
  group('tryDecodeText', () {
    test('UTF-8 纯文本', () {
      final r = tryDecodeText(utf8.encode('你好，世界。'));
      expect(r, isNotNull);
      expect(r!.text, '你好，世界。');
      expect(r.encoding, 'UTF-8');
    });

    test('UTF-8 带 BOM：内容里不能留下不可见字符', () {
      final r = tryDecodeText(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('开头。')]));
      expect(r!.text, '开头。', reason: 'BOM 必须被剥掉，否则第一句会多出 U+FEFF');
      expect(r.encoding, 'UTF-8');
    });

    test('GB18030 中文：自动识别并正确解码', () {
      final r = tryDecodeText(_gb18030Chinese);
      expect(r, isNotNull, reason: '中文 Windows 导出的 txt 必须能读进来');
      expect(r!.text, '中文测试内容。ABC 123');
      expect(r.encoding, 'GB18030');
    });

    test('GB18030 四字节区（GBK 无法表示的字符）', () {
      final r = tryDecodeText(_gb18030FourByte);
      expect(r, isNotNull);
      expect(r!.text, '\u{20000}', reason: '四字节区只有真正的 GB18030 codec 能解');
      expect(r.encoding, 'GB18030');
    });

    test('UTF-16 LE / BE：按 BOM 判定', () {
      final le = Uint8List.fromList([0xFF, 0xFE, ..._toLeBytes('中文')]);
      final r1 = tryDecodeText(le);
      expect(r1!.text, '中文');
      expect(r1.encoding, 'UTF-16');

      final be = Uint8List.fromList([0xFE, 0xFF, ..._toBeBytes('中文')]);
      final r2 = tryDecodeText(be);
      expect(r2!.text, '中文');
      expect(r2.encoding, 'UTF-16');
    });

    test('西欧 Windows-1252 文件：不该被自动当成 GB18030', () {
      // "Café" 的 cp1252 字节；0xE9 作首字节找不到合法次字节
      final bytes = Uint8List.fromList([0x43, 0x61, 0x66, 0xE9]);
      expect(tryDecodeText(bytes), isNull,
          reason: '解出来是乱码就宁可不猜，交给界面弹窗问用户');
    });

    test('空文件', () {
      expect(tryDecodeText(Uint8List(0)), isNull);
    });
  });

  group('looksLikeText', () {
    test('正常中文与英文', () {
      expect(looksLikeText('中文测试内容。ABC 123'), isTrue);
      expect(looksLikeText('line1\nline2\ttab'), isTrue);
    });

    test('控制符过多判为不像文字', () {
      expect(looksLikeText(''), isFalse);
      expect(looksLikeText(''), isFalse);
    });
  });

  group('tryDecodeGb18030', () {
    test('弹窗里手动选 GB18030 时可用', () {
      expect(tryDecodeGb18030(_gb18030Chinese), '中文测试内容。ABC 123');
    });
  });
}

List<int> _toLeBytes(String s) {
  final out = <int>[];
  for (final u in s.codeUnits) {
    out..add(u & 0xFF)..add((u >> 8) & 0xFF);
  }
  return out;
}

List<int> _toBeBytes(String s) {
  final out = <int>[];
  for (final u in s.codeUnits) {
    out..add((u >> 8) & 0xFF)..add(u & 0xFF);
  }
  return out;
}
