import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sayit_app/main.dart';

void main() {
  setUp(() {
    // main() 的 initState 现在会读 SharedPreferences（音色 / 语速等），
    // 测试环境里没有平台实现，必须先塞 mock，否则 getInstance() 直接抛
    // MissingPluginException。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('SayIt app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SayItApp());
    await tester.pumpAndSettle();

    expect(find.text('说吧'), findsWidgets);
    expect(find.text('输入文本'), findsOneWidget);
    expect(find.text('分句'), findsOneWidget);
    expect(find.text('生成并播放'), findsOneWidget);
  });

  // 回归测试：帮助对话框曾经长期与实际行为相反 ——
  // 写着「保存为 WAV 文件」「序号_前10个字.wav」「导出为无损 WAV 而不是 MP3」，
  // 还列了一张句间停顿表（。！？ 500ms…），而导出格式一直是 MP3、
  // 句间停顿功能早已整体删除。改代码的人很容易再次让它漂移，这里钉住。
  testWidgets('帮助对话框必须如实描述 MP3 导出，且不再承诺句间停顿',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SayItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('帮助'));
    await tester.pumpAndSettle();

    expect(find.textContaining('MP3'), findsWidgets,
        reason: '帮助里要说明导出的是 MP3');

    expect(find.textContaining('WAV'), findsNothing,
        reason: 'edge_tts 固定输出 MP3，帮助里不该再出现 WAV');
    expect(find.textContaining('PCM'), findsNothing,
        reason: '拿不到 PCM，这个说法本身就是错的');
    expect(find.textContaining('500ms'), findsNothing,
        reason: '句间停顿功能已删除，不能再承诺具体的停顿毫秒数');
  });
}
