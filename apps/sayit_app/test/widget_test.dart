import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sayit_app/main.dart';

/// 应用允许的最小窗口尺寸。
///
/// 与 macOS 的 `MainFlutterWindow.swift`、Windows 的 `WM_GETMINMAXINFO`、
/// Linux 的 `set_size_request` 保持一致。界面是固定布局，窗口再矮就会挤爆，
/// 所以三个平台都挡住了最小尺寸，这里用同样的尺寸做回归。
const _minWindowSize = Size(780, 760);

void main() {
  setUp(() {
    // main() 的 initState 现在会读 SharedPreferences（音色 / 语速等），
    // 测试环境里没有平台实现，必须先塞 mock，否则 getInstance() 直接抛
    // MissingPluginException。
    SharedPreferences.setMockInitialValues({});
  });

  /// 把测试视口设成最小窗口尺寸。
  void useMinWindow(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = _minWindowSize;
    addTearDown(tester.view.reset);
  }

  testWidgets('SayIt app smoke test', (WidgetTester tester) async {
    useMinWindow(tester);

    await tester.pumpWidget(const SayItApp());
    await tester.pumpAndSettle();

    expect(find.text('说吧'), findsWidgets);
    expect(find.text('输入文本'), findsNothing,
        reason: '输入区改成了面板标题，不再用 labelText');
    expect(find.text('文本输入'), findsOneWidget);
    expect(find.text('分句'), findsOneWidget);
    expect(find.text('生成并播放'), findsOneWidget);
  });

  // 回归测试：帮助对话框曾经长期与实际行为相反 ——
  // 写着「保存为 WAV 文件」「序号_前10个字.wav」「导出为无损 WAV 而不是 MP3」，
  // 还列了一张句间停顿表（。！？ 500ms…），而导出格式一直是 MP3、
  // 句间停顿功能早已整体删除。改代码的人很容易再次让它漂移，这里钉住。
  testWidgets('帮助对话框必须如实描述 MP3 导出，且不再承诺句间停顿',
      (WidgetTester tester) async {
    useMinWindow(tester);

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

  // 回归测试：界面是固定布局，窗口太矮会 RenderFlex overflowed。
  // 三个平台都设了最小窗口尺寸，这里用同样的尺寸确认布局塞得下。
  testWidgets('最小窗口尺寸下不能出现布局溢出', (WidgetTester tester) async {
    useMinWindow(tester);

    await tester.pumpWidget(const SayItApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  // 回归测试：滑块所在区域不允许有外层滚动容器。
  //
  // 以前整块「输入 + 按钮 + 滑块」裹在一个纵向 SingleChildScrollView 里，
  // 拖动滑块时会跟外层滚动抢手势，macOS 上还会冒出一条常驻滚动条。
  // 现在界面上只允许两处滚动：文本输入框内部、音频文件列表。
  testWidgets('滑块区不落在任何滚动容器里', (WidgetTester tester) async {
    useMinWindow(tester);

    await tester.pumpWidget(const SayItApp());
    await tester.pumpAndSettle();

    for (final label in ['语速', '音高', '音量']) {
      final slider = find.ancestor(
        of: find.text(label),
        matching: find.byType(Scrollable),
      );
      expect(slider, findsNothing,
          reason: '「$label」所在区域不应该有 Scrollable 祖先');
    }
  });
}
