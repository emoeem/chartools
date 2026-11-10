// 首页冒烟测试：五个内置场景要能全部渲染出来。
import 'package:chartools_app/application/settings_store.dart';
import 'package:chartools_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('首页展示五个内置场景', (WidgetTester tester) async {
    // 冒烟测试只看渲染：不给 store 调 load()（那要走平台通道），
    // 直接用内存默认值。
    await tester.pumpWidget(ChartoolsApp(store: SettingsStore()));

    expect(find.text('通用沟通助手'), findsOneWidget);
    expect(find.text('聊天副驾'), findsOneWidget);
    expect(find.text('客服坐席辅助'), findsOneWidget);
    expect(find.text('外语学习陪练'), findsOneWidget);
    expect(find.text('直播/社群互动'), findsOneWidget);
    expect(find.text('社交辅助（无障碍）'), findsOneWidget);
    // 采集目标标签：'微信' 出现在外语陪练与社交辅助两个场景，'千牛' 只在客服坐席。
    expect(find.text('微信'), findsNWidgets(2));
    expect(find.text('千牛'), findsOneWidget);
  });
}
