import 'package:flutter_test/flutter_test.dart';
import 'package:sayit_app/src/tts_error.dart';

/// 实测拿到的真实 403 报错（sayit-poc stderr 原样）
const _real403 = "Error: Python 子进程退出非零（含 stderr）：stream: 403, "
    "message='Invalid response status', "
    "url='wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/"
    "edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&"
    "ConnectionId=1e64f0a7823f47418171e8f2588ea3d5&"
    "Sec-MS-GEC=0ABD9FB0FEC7254FB3055EEE150BDDCA03BECCAA6A169E28D4D0945F014A0576&"
    "Sec-MS-GEC-Version=1-143.0.3650.75'";

void main() {
  group('sanitizeTtsError', () {
    test('403：砍掉 URL 并翻译成人话', () {
      final r = sanitizeTtsError(_real403);
      expect(r, isNot(contains('TrustedClientToken')),
          reason: 'DRM 令牌对用户毫无用处，不该显示');
      expect(r, isNot(contains('Sec-MS-GEC')), reason: '同理');
      expect(r, isNot(contains('wss://')), reason: '整条 URL 都该去掉');
      expect(r, contains('403'), reason: '要保留状态码');
      expect(r, contains('代理'), reason: '要告诉用户最可能的原因');
    });

    test('403：长度必须显著短于原始报错', () {
      final raw = _real403.length;
      final clean = sanitizeTtsError(_real403).length;
      expect(raw, greaterThan(350), reason: '原始报错确实是这么长（回归基线）');
      expect(clean, lessThan(raw ~/ 2),
          reason: '清洗后应不到原始长度的一半，实际 $clean / $raw');
    });

    test('403：即使没有 Invalid response status 也认得出来', () {
      final r = sanitizeTtsError('some error: 403 Forbidden');
      expect(r, contains('代理'));
      expect(r, contains('403'));
    });

    test('双引号形式的 url 参数也能去掉', () {
      final r = sanitizeTtsError('failed 403, url="wss://x/y?token=abc"');
      expect(r, isNot(contains('token=abc')));
      expect(r, isNot(contains('wss://')));
    });

    test('非 403 的普通报错不做改写（不乱动用户需要的信息）', () {
      const msg = '找不到 python3：请安装 Python 3.8+ 并确保在 PATH 中。';
      expect(sanitizeTtsError(msg), contains('Python 3.8+'));
      expect(sanitizeTtsError(msg), isNot(contains('微软拒绝')));
    });

    test('空输入不炸', () {
      expect(sanitizeTtsError(''), '');
      expect(sanitizeTtsError('   \n  '), '');
    });
  });
}
