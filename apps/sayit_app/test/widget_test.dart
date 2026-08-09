import 'package:flutter_test/flutter_test.dart';
import 'package:sayit_app/main.dart';

void main() {
  testWidgets('SayIt app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SayItApp());
    await tester.pumpAndSettle();

    expect(find.text('说吧'), findsWidgets);
    expect(find.text('输入文本'), findsOneWidget);
    expect(find.text('分句'), findsOneWidget);
    expect(find.text('生成并播放'), findsOneWidget);
  });
}
