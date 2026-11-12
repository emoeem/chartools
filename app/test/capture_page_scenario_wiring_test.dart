import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chartools_app/application/settings_store.dart';
import 'package:chartools_app/main.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 场景接线的 widget 级钉子（fix(#11 P0-N) 独立复核补接）。
///
/// 独立复核发现：store.scenarioId（引导页写入、settings_store.dart 持久化）
/// 只接到了 DesktopAssistantPage 两处入口，首页 AppBar 推入的 [CapturePage]
/// 没传、页面类连参数都没有——采集流每轮 `resolveScenario(scenarioId: null)`
/// 返回 null，用户选的客服坐席/外语陪练/社交辅助场景对 Android 采集流零效果。
/// 既有测试全绿是因为没有任何 widget 级测试覆盖 main.dart → CapturePage 这段
/// 接线（notifier 级测试直接注入 session、core 的 scenario_pipeline_test 测
/// JevClient 层，都照不到 UI 断线）。本文件把同一件事钉在**真实 UI 路径**上：
///
///  1. pump 生产根组件 [ChartoolsApp]（首页 ScenarioListPage）；
///  2. 点首页 AppBar 的采集入口（Android 独占 IconButton，main.dart 的唯一
///     CapturePage 构造点）推入采集页；
///  3. mock EventChannel 推一条快照（置信度缺省 1.0，高于 G3 门控 → 自动起轮）；
///  4. 出网请求经 `HttpOverrides.global` 换成进程内替身（见下方说明），断言
///     **起草请求的双提示词里真的有**所选场景的附加段（system/user 两段都查，
///     与 core 的 scenario_pipeline_test 同一断言口径——那边证明 JevClient 会
///     带，这边证明 UI 接线没断）。
///
/// 反向用例：scenarioId 是空串（未引导）时，同一 UI 路径的起草请求不带附加段
/// ——防止修复被改成「硬编码一个场景」这类过拟合。
///
/// ## 为什么是 HttpOverrides 而不是本地 HttpServer
///
/// testWidgets 跑在 FakeAsync zone：本地真 socket 的 connect/响应是真实 IO，
/// 实测（探针）在 pump/runAsync 交替下永远打不到本地桩——真实事件回调被排进
/// FakeAsync 的微任务队列，而 socket 事件根本不经过它。`HttpOverrides.global`
/// 由 dart:io 的 `HttpClient()` 工厂直接消费（不受 zone 限定），把 [HttpJson]
/// 的静态客户端换成进程内替身后，整条 judge → draft → rank 链路纯微任务驱动，
/// pump 即可确定性地推进（替身只实现 HttpJson 用到的 happy-path 成员，其余经
/// noSuchMethod 吞掉）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页进采集页：store.scenarioId 选中的场景附加段随起草请求出网',
      (tester) async {
    final stub = _installHttpStub();
    addTearDown(stub.uninstall);

    final store = _storeFor(stub, scenarioId: 'support_agent');

    // 采集入口只在 Android 出现（main.dart 的平台分支）；widget 测试默认
    // TargetPlatform 以 debug override 为准。override 必须在测试体结束前
    // 复位（框架在 tearDown 之前校验 foundation debug 变量不变式），用
    // try/finally 保证。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _runScenarioWiringCase(tester, stub, store, expectAddendum: true);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('首页进采集页：scenarioId 为空串（未引导）时起草请求不带附加段',
      (tester) async {
    final stub = _installHttpStub();
    addTearDown(stub.uninstall);

    // 未引导：store.scenarioId 缺省就是空串（settings_store.dart 契约）。
    final store = _storeFor(stub);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _runScenarioWiringCase(tester, stub, store, expectAddendum: false);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 两个用例的公共主体：pump 生产首页 → 点采集入口进 CapturePage → 注入快照
/// → pump 跑完整轮 → 断言起草请求里附加段的有无。
Future<void> _runScenarioWiringCase(
  WidgetTester tester,
  _StubDispatcher stub,
  SettingsStore store, {
  required bool expectAddendum,
}) async {

    // 采集页进页会查/下发三条通道（快照流、control、插件通道）；桩到最小应答：
    // 服务未连接（isRunning false）、configure/showSuggestions 照常成功，页面
    // 状态卡/配置下发不报错。快照事件稍后经 mock 的 EventChannel 注入。
    final binding = TestDefaultBinaryMessengerBinding.instance;
    // EventChannel 缺省 codec 是 StandardMethodCodec（capture_android.dart 的
    // _snapshots 没有显式给 codec）——注入事件必须用同款编码。
    const snapshotsMock = MethodChannel('capture_android/snapshots');
    const controlMock = MethodChannel('capture_android/control');
    const pluginMock = MethodChannel('capture_android');
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(snapshotsMock, (call) async => null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(controlMock, (call) async {
      switch (call.method) {
        case 'configure':
          return true;
        case 'isRunning':
          return false; // 服务未连接：状态卡显示未连接，不影响起轮。
        case 'showSuggestions':
          return true;
        case 'isSecure':
          return false;
        default:
          return null;
      }
    });
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(pluginMock, (call) async => false);
    addTearDown(() {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(snapshotsMock, null);
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(controlMock, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(pluginMock, null);
    });

    // 生产根组件：首页 → AppBar 采集入口 → CapturePage（修复的接线在
    // main.dart 的这个构造点）。
    await tester.pumpWidget(ChartoolsApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.assistant));
    await tester.pumpAndSettle();

    // 原生侧推一条快照（EventChannel 事件 = JSON 字符串；confidence 缺省
    // 1.0 > G3 阈值 0.5，走自动分析 → judge → draftAndRank）。
    binding.defaultBinaryMessenger.handlePlatformMessage(
      'capture_android/snapshots',
      const StandardMethodCodec()
          .encodeSuccessEnvelope(jsonEncode(const {
        'title': '测试会话',
        'messages': [
          {'side': 'other', 'text': '周末有空吗'},
          {'side': 'me', 'text': '在加班，周五之前都悬'},
        ],
      })),
      (_) {},
    );

    // 替身全程微任务驱动：pump 推进 FakeAsync 时钟即可跑完整轮
    // （judge → draft → rank → 写 state），无需真实 IO。
    final support = Scenarios.byId('support_agent')!;
    await _pumpUntilDraft(tester, stub);

    expect(stub.draftCalls, greaterThanOrEqualTo(1),
        reason: '快照进门后必须走到起草请求（接线断链时这里收不到出网）；'
            '替身计数 judge=${stub.judgeCalls} rank=${stub.rankCalls} '
            'draft=${stub.draftCalls} total=${stub.totalRequests} '
            'err=${stub.lastError}');
    if (expectAddendum) {
      expect(stub.lastDraftSystem, contains(support.systemAddendum),
          reason: 'store.scenarioId 选中的场景附加段必须随起草 system 提示词出网');
      expect(stub.lastDraftUser, contains(support.userAddendum),
          reason: 'store.scenarioId 选中的场景附加段必须随起草 user 提示词出网');
    } else {
      // 空串场景必须落到「无场景」（Scenarios.byId 返回 null 的约定）——
      // 防止修复被改成「硬编码一个场景」这类过拟合。
      expect(stub.lastDraftSystem, isNot(contains(support.systemAddendum)));
      expect(stub.lastDraftUser, isNot(contains(support.userAddendum)));
    }
  }

/// 给当前 isolate 安装进程内 HTTP 替身（`HttpOverrides.global`，dart:io 的
/// `HttpClient()` 工厂直接消费，FakeAsync zone 里同样生效），并显式摸一次
/// [HttpJson] 强迫其静态客户端在替身在场时初始化。`uninstall` 摘掉替身。
_StubDispatcher _installHttpStub() {
  final dispatcher = _StubDispatcher();
  _activeDispatcher = dispatcher;
  HttpOverrides.global = _StubHttpOverrides();
  // HttpJson 的静态 `_client` 在类首次触碰时初始化——此刻替身必须在场。
  HttpJson.jsonRequestHeaders('probe', const {});
  return dispatcher;
}

/// 测试用 SettingsStore：模型路由指向替身（地址不出网，反正客户端已是替身），
/// 场景按用例注入。
SettingsStore _storeFor(_StubDispatcher stub, {String scenarioId = ''}) {
  final store = SettingsStore();
  store.config.value = JevConfig()
    ..judgeBaseUrl = 'http://stub.invalid'
    ..judgeKey = 'test-key'
    ..judgeModel = 'judge-model'
    ..replyBaseUrl = 'http://stub.invalid'
    ..replyKey = 'test-key'
    ..replyModel = 'reply-model';
  store.scenarioId.value = scenarioId;
  return store;
}

/// 全程微任务驱动：pump 推进 FakeAsync 时钟直到起草请求抵达替身。
/// 超时由后续 expect 给出可读的失败原因，这里只保证终止。
Future<void> _pumpUntilDraft(WidgetTester tester, _StubDispatcher stub) async {
  for (var i = 0; i < 100 && stub.draftCalls == 0; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

/// 进程内替身：把 judge（decisions 协议）/起草/排序按请求体形状分诊应答，
/// 记录起草请求的出网双提示词（断言对象）。与 core 的
/// scenario_pipeline_test.StubServer 同一套分诊口径。
class _StubDispatcher {
  int draftCalls = 0;
  int judgeCalls = 0;
  int rankCalls = 0;
  int totalRequests = 0;

  String lastDraftSystem = '';
  String lastDraftUser = '';
  String lastError = '';

  void uninstall() {
    HttpOverrides.global = null;
    _activeDispatcher = null;
  }

  /// 请求进站（_StubRequest.close 时调）。返回应答 JSON 字符串。
  String handle(String raw) {
    totalRequests++;
    try {
      final body = jsonDecode(raw) as Map<String, dynamic>;
      if (body.containsKey('questions')) {
        // decisions 协议（judge/rank 同址）：按题目集合分诊。
        final questions = body['questions'] as Map<String, dynamic>;
        if (questions.containsKey('best_reply')) {
          rankCalls++;
          return jsonEncode(const {
            'answers': {
              'best_reply': {
                'choice': 'reply_b',
                'confidence': 0.9,
                'probabilities': {
                  'reply_a': 0.2,
                  'reply_b': 0.7,
                  'reply_c': 0.1,
                },
              },
            },
          });
        }
        judgeCalls++;
        // 全空 answers：Analysis 各字段缺省、error 为 null，照常进起草。
        return jsonEncode(const {'answers': <String, dynamic>{}});
      }
      // chat/completions 起草：记录出网双提示词（断言对象），回合法候选。
      draftCalls++;
      final messages = body['messages'] as List<dynamic>;
      lastDraftSystem =
          (messages.first as Map<String, dynamic>)['content'] as String? ?? '';
      lastDraftUser =
          (messages.last as Map<String, dynamic>)['content'] as String;
      return jsonEncode(const {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': _draftReply,
            },
          },
        ],
      });
    } catch (e, s) {
      // 替身侧的解析失败不是测试失败本身：记下来随 expect reason 一起报出。
      lastError = '$e\n$s';
      return jsonEncode(const {'answers': <String, dynamic>{}});
    }
  }
}

class _StubHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _StubHttpClient();
}

/// 只实现 HttpJson happy-path 用到的成员（openUrl），其余经 noSuchMethod 吞掉
/// （如 HttpJson 静态初始化时的 `..connectionTimeout` 级联）。
class _StubHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _StubRequest(url);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubRequest implements HttpClientRequest {
  _StubRequest(this.url);

  final Uri url;
  final StringBuffer _body = StringBuffer();

  @override
  final HttpHeaders headers = _StubHeaders();

  @override
  void write(Object? obj) => _body.write(obj);

  @override
  Future<HttpClientResponse> close() async =>
      _StubResponse(200, _dispatcherHandle(_body.toString()));

  @override
  void abort([Object? cause, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 请求体分诊进当前替身。静态 `HttpJson._client` 是 isolate 单份，替身对象
/// 经 [_activeDispatcher] 按用例切换；每个用例起轮前各自 install，断言互不串。
String _dispatcherHandle(String raw) => _activeDispatcher!.handle(raw);

/// 当前替身（_installHttpStub 时设定、uninstall 时清空）。
_StubDispatcher? _activeDispatcher;

class _StubHeaders implements HttpHeaders {
  final Map<String, String> _map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map[name] = '$value';

  @override
  String? value(String name) => _map[name];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// HttpJson 读响应走 `resp.transform(utf8.decoder)`——继承 Stream 让 transform/
/// bind 等默认实现直接可用，statusCode/headers 走 HttpClientResponse 声明。
class _StubResponse extends Stream<List<int>> implements HttpClientResponse {
  _StubResponse(this.statusCode, String body) : _data = utf8.encode(body);

  @override
  final int statusCode;

  @override
  final HttpHeaders headers = _StubHeaders();

  final List<int> _data;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_data).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 三条候选的桩答复（与 core 的 scenario_pipeline_test 逐字同口径）。
const String _draftReply = '['
    '{"strategy":"safe","text":"先接住她，别急着解释"},'
    '{"strategy":"forward","text":"我想你了，这周末见一面？"},'
    '{"strategy":"angle","text":"换我主动汇报行程，如何？"}'
    ']';
