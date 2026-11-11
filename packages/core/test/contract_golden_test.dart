import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 双端契约金样（kimi-review #17 的 Dart 侧）。
///
/// 快照 JSON 的 Kotlin 序列化（CaptureService.snapshotJson）与 Dart 反序列化
/// （[ChatSnapshot.fromJson]）各自手写、此前零测试，靠人肉镜像维持。金样是
/// 一行 JSON 字面量，**与 Kotlin 侧
/// packages/capture_android/android/src/test/kotlin/dev/chartools/capture/SignatureContractTest.kt
/// 的 GOLDEN 逐字节同内容**——改其中一份必须先改另一份，让「契约变了」在
/// 评审里显式发生（与 reply_prompt_gold_test 的金样思路一致：改契约必须先过
/// 金样这道显式门槛）。
///
/// 样例按 CaptureService 真实 OCR 路径装配（provenance=ocr、一条 unknown
/// speaker、标题在）：
/// - confidence = OCR 基线 0.6 − 一条 unknown-speaker 0.1 = 精确 0.5（恰为 G3
///   门控阈值，与 SnapshotConfidenceContractTest 的贴线用例同值）；
/// - uncertain = ['发言人未知']（UNCERTAIN_UNKNOWN_SPEAKER，CaptureService.kt）；
/// - note = 'OCR 分边：有 1 条'（CaptureService.kt 的 OCR_PARTIAL_NOTE 拼法）；
/// - messages 只带 side/text（snapshotJson 不序列化 id/at/sender/history）。
///
/// 与本金样同住此文件的另两份机器钳制：
/// - 快照签名口径（kimi-review #21）：Dart `ChatSnapshot.signature()` 与
///   Kotlin `Model.kt signature()` 钉死同一期望串 —— 两端口径一致，允许跨端
///   对拍；
/// - B8 展示模式字符串（kimi-review #17b）：Dart SettingsStore 常量与 Kotlin
///   OverlayController.MODE_PRIMARY 运行时互不可见（app 包 ↔ 插件），镜像靠
///   本文件的源码扫描钳住。
void main() {
  group('快照 JSON 金样 ↔ ChatSnapshot.fromJson（kimi-review #17）', () {
    final golden = jsonDecode(goldenSnapshotJson) as Map<String, dynamic>;

    test('金样键集恰为通道契约六字段（顺序 = snapshotJson 发射序）', () {
      // CaptureService.snapshotJson 的发射集：title/note/provenance/confidence/
      // uncertain?/messages（messages 项恰为 side/text）。Kotlin 侧对同一金样
      // 断言同一键序——两端同改才算改。
      expect(golden.keys.toList(),
          ['title', 'note', 'provenance', 'confidence', 'uncertain', 'messages']);
    });

    test('fromJson 把金样每个字段都解析到位', () {
      final s = ChatSnapshot.fromJson(golden);
      expect(s.title, '小美');
      expect(s.note, 'OCR 分边：有 1 条');
      expect(s.provenance, Provenance.ocr);
      // G3 门控阈值：0.6 基线 − 一条 unknown-speaker 0.1。
      expect(s.confidence, 0.5);
      expect(s.uncertain, ['发言人未知']);
      expect(s.messages.map((m) => m.side).toList(), ['?', 'me', 'other']);
      expect(s.messages.map((m) => m.text).toList(), ['在吗', '刚下班', '辛苦了']);
      // snapshotJson 只发 side/text：id/at/sender 在 Dart 侧回缺省。
      for (final m in s.messages) {
        expect(m.id, isNull);
        expect(m.at, 0);
        expect(m.sender, isNull);
      }
    });

    test('旧 JSON 解析不破：无 confidence/uncertain 时缺省 1.0 与空表', () {
      // 通道契约（models.dart fromJson kdoc）：旧 JSON 无 G3 两字段时解析
      // 结果与改前完全一致。legacy 由金样去掉两键派生，不另立第二份金样。
      final legacy = Map<String, dynamic>.of(golden)
        ..remove('confidence')
        ..remove('uncertain');
      final s = ChatSnapshot.fromJson(legacy);
      expect(s.confidence, 1.0);
      expect(s.uncertain, isEmpty);
      expect(s.title, '小美');
      expect(s.messages.map((m) => m.text).toList(), ['在吗', '刚下班', '辛苦了']);
    });

    test('confidence 越界夹回 0.0..1.0；uncertain 非字符串项丢弃', () {
      // fromJson 的防御性解析（通道对端不可信）：越界夹回、坏类型丢弃。
      final over = Map<String, dynamic>.of(golden)..['confidence'] = 1.7;
      expect(ChatSnapshot.fromJson(over).confidence, 1.0);
      final under = Map<String, dynamic>.of(golden)..['confidence'] = -0.3;
      expect(ChatSnapshot.fromJson(under).confidence, 0.0);
      final noisy = Map<String, dynamic>.of(golden)
        ..['uncertain'] = ['发言人未知', 42, null];
      expect(ChatSnapshot.fromJson(noisy).uncertain, ['发言人未知']);
    });
  });

  group('快照签名口径（kimi-review #21）：两端口径一致，允许跨端对拍', () {
    test('金样三条消息的签名与 Kotlin 侧 SignatureContractTest 同串', () {
      final s =
          ChatSnapshot.fromJson(jsonDecode(goldenSnapshotJson) as Map<String, dynamic>);
      // 期望串与 Kotlin 侧 GOLDEN_SIGNATURE 同串：任何一端改格式（分隔符/
      // 条数/键序），两边的测试同时红。
      expect(s.signature(), goldenSignature);
    });

    test('口径钉死：末 6 条、每条 side:text、以 | 连接', () {
      final seven = ChatSnapshot(
        messages: [
          for (var i = 0; i < 7; i++) Msg(side: 'me', text: 'm$i'),
        ],
      );
      // 第 0 条被末 6 条语义挤出（skip(len-6)，与 Kotlin takeLast(6) 等价）。
      expect(seven.signature(), 'me:m1|me:m2|me:m3|me:m4|me:m5|me:m6');
      final short = ChatSnapshot(
        messages: [
          const Msg(side: 'other', text: 'a'),
          const Msg(side: 'me', text: 'b'),
        ],
      );
      expect(short.signature(), 'other:a|me:b');
      // 评审口径里的另一种历史写法（/ 连接）不许回潮。
      expect(short.signature(), isNot(contains('/')));
    });
  });

  group('B8 展示模式字符串（kimi-review #17b）：两侧常量的机器钳制', () {
    // 注释互相指路：
    //   Dart 侧常量 —— app/lib/application/settings_store.dart
    //   （displayModePrimary / displayModeAll）；
    //   Kotlin 侧常量 —— packages/capture_android/…/overlay/OverlayController.kt
    //   （MODE_PRIMARY，private，注释已写「与 Dart 侧 SettingsStore 常量镜像」）。
    // 两侧运行时互不可见，字符串靠手写镜像；这里用源码扫描钳住两端字面量与
    // 通道键：任何一端改值/改名/删除，本组即红（settings_store.dart 归 app
    // 所有、OverlayController.kt 归插件所有，本文件不越权改它们，只钳）。
    final root = _repoRoot();

    test('Dart 侧常量与插件通道键未被改动', () {
      expect(root, isNotNull,
          reason: '在仓库内找不到 app/ 与 packages/ —— mode 契约扫描失位，'
              '请确认从 chartools-next 仓库内跑 core 测试');
      final settings = _sourceOf(root!, 'app/lib/application/settings_store.dart');
      expect(
        RegExp(r"static const String displayModePrimary\s*=\s*'primary'")
            .hasMatch(settings),
        isTrue,
        reason: 'settings_store.displayModePrimary 改值/改名 → Kotlin 侧 '
            'OverlayController.MODE_PRIMARY 的镜像要同步改，两侧测试都要动',
      );
      expect(
        RegExp(r"static const String displayModeAll\s*=\s*'all'")
            .hasMatch(settings),
        isTrue,
        reason: 'displayModeAll 在 Kotlin 侧无同名常量（≠primary 一律平铺），'
            '但字符串仍须留在此处供通道透传',
      );
      final facade = _sourceOf(root, 'packages/capture_android/lib/capture_android.dart');
      expect(
        RegExp(r"'mode':\s*mode").hasMatch(facade),
        isTrue,
        reason: 'showSuggestions 的通道键仍是 mode（Kotlin 侧同名读取，下一条）',
      );
    });

    test('Kotlin 侧常量与通道读取未被改动', () {
      expect(root, isNotNull, reason: '同上：仓库根定位失败');
      final overlay = _sourceOf(
        root!,
        'packages/capture_android/android/src/main/kotlin/dev/chartools/capture/'
        'overlay/OverlayController.kt',
      );
      expect(
        RegExp(r'MODE_PRIMARY\s*=\s*"primary"').hasMatch(overlay),
        isTrue,
        reason: 'OverlayController.MODE_PRIMARY 改值 → settings_store.'
            'displayModePrimary 的镜像要同步改，两侧测试都要动',
      );
      final service = _sourceOf(
        root,
        'packages/capture_android/android/src/main/kotlin/dev/chartools/capture/'
        'CaptureService.kt',
      );
      expect(
        service.contains('call.argument<String>("mode")'),
        isTrue,
        reason: 'Kotlin 侧读取键仍是 mode（capture_android.dart 同名发送）',
      );
    });
  });
}

/// 金样本体：与 Kotlin 侧 SignatureContractTest.kt 的 GOLDEN 逐字节同内容
/// （互为镜像，改一份必改另一份，见文件头注释）。
const String goldenSnapshotJson =
    '{"title":"小美","note":"OCR 分边：有 1 条","provenance":"ocr",'
    '"confidence":0.5,"uncertain":["发言人未知"],"messages":[{"side":"?",'
    '"text":"在吗"},{"side":"me","text":"刚下班"},{"side":"other","text":"辛苦了"}]}';

/// 跨端签名期望串：与 Kotlin 侧 GOLDEN_SIGNATURE 同串（kimi-review #21 的
/// 「两端口径一致，允许跨端对拍」的锚）。
const String goldenSignature = '?:在吗|me:刚下班|other:辛苦了';

/// 从 CWD 向上找仓库根：同时容得下 app/ 与 packages/ 两个扫描目标即认。
/// dart test 的 CWD 是包目录（packages/core，benchmark_test.dart 的相对路径
/// 同此假设）；向上多走几级让「从 workspace 根跑」也成立。
Directory? _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/app/lib/application/settings_store.dart').existsSync() &&
        File('${dir.path}/packages/capture_android/lib/capture_android.dart')
            .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}

/// 读仓库内相对路径的源文件；找不到就响亮地失败——契约钳制不许静默消失。
String _sourceOf(Directory root, String relative) {
  final f = File('${root.path}/$relative');
  if (!f.existsSync()) {
    fail('契约扫描找不到 $relative —— 仓库结构变了，请同步修本文件的扫描路径');
  }
  return f.readAsStringSync();
}
