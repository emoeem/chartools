/// P0 判断路由降级的会话级回归测试（capture_session._runRound / regenerate）。
///
/// 用「进程内 mock 模型服务器（HttpOverrides 替身）+ manualOcr 通道 mock」驱动
/// 一轮完整的「采集 → 判断 → 起草」，钉住裁定方案的每一条：
///
/// 1. **全新安装（出厂默认配置）**：起草请求正常构造、候选非空，且
///    **不含任何 judge 网络调用**（连 /alpha/decisions 都不出现）——判断路由
///    未配置就跳过判断，合成空判断直接起草；#11/#13 的 scenarioId /
///    knowledgeBase 链路在同轮不受降级影响（场景附加段与知识参考照常进
///    起草提示词）。
/// 2. **judge 已配置但调用失败**：照样降级起草（候选非空），错误留在
///    state 的可见位置（`CaptureState.analysis.error`，桌面页按它渲染判断
///    错误卡），不静默吞；顶层 CaptureState.error 不写——采集页错误卡与
///    候选列表互斥（capture_page._suggestionsSection），写了它等于从后门
///    复刻「候选恒空」。
/// 3. **judge 已配置且成功**：判断字段照常进 state 与起草提示词（非降级
///    路径零回归），F1 策略提升照常生效。
/// 4. **judgeProvider=跟随回复路由**：judge 调用落点就是回复端点
///    （openai_chat 语义），密钥随回复路由（Authorization: Bearer reply-key）、
///    模型随 replyModel。
/// 5. **「换一组」在降级态**：盲写重起草，候选保留，错误标注不丢，提示词
///    不引入判断噪声块（与首轮降级同构）。
///
/// 「判断噪声块」的断言口径：judgmentBlock(空/失败判断) 会产出
/// 「判断结果（先按它读局势，再写回复）：看不出×3」——降级轮的起草 user
/// 提示词**不得**出现「判断结果（」开头；成功轮**必须**出现（证明判断真的
/// 进了提示词，不是两头都靠「没有」蒙混）。
///
/// 本文件为新增（不改 capture_session_scenario_test.dart 等既有测试）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chartools_app/application/capture_session.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进程内 mock 模型服务器（不走真实 socket）：按请求路径与请求体分流
/// （draft / judge-decisions / judge-chat），记录每个请求的路径、
/// Authorization 与解析后的 JSON 体。
///
/// 为什么是 `HttpOverrides.global` 替身而不是本机 `HttpServer`：本测试要装
/// `TestWidgetsFlutterBinding`（通道 mock 需要），而绑定初始化时会把
/// `HttpOverrides.global` 换成「一律应 400」的假客户端（flutter_test 的已知
/// 行为，失败警告原文：all HTTP requests will return status code 400）——
/// 真实 HttpServer 绑得上、请求根本到不了。同仓库
/// capture_page_scenario_wiring_test.dart:35 的说明一脉相承：出网请求经
/// `HttpOverrides.global` 换成进程内替身后，整条 judge → draft → rank 链路
/// 纯微任务驱动，替身只实现 HttpJson happy-path 用到的成员，其余经
/// noSuchMethod 吞掉。
class _MockModelServer {
  final List<_RecordedRequest> requests = [];

  /// judge 决策路由的应答状态码：401 = 「已配置但调用失败」场景（客户端
  /// 错误不重试，单次往返）；200 = 成功场景。
  int judgeDecisionsStatus = 200;

  /// 判断路由 base（judgeBaseUrl 指向这里 → 端点 {base}/alpha/decisions）。
  /// 替身不出网：地址只须满足「绝对 http(s) 地址」判据与 Uri 解析。
  String get judgeBase => 'http://stub.invalid';

  /// 回复路由 base（到 /v1 为止）。
  String get replyBase => 'http://stub.invalid/v1';

  /// 安装替身并显式摸一次 [HttpJson]：其静态 `_client` 在类首次触碰时经
  /// `HttpClient()` 工厂创建——此刻替身必须在场（否则拿到绑定装的原件假
  /// 客户端，整轮 400）。同款探针见 wiring test 的 _installHttpStub。
  void install() {
    HttpOverrides.global = _StubHttpOverrides();
    _activeServer = this;
    HttpJson.jsonRequestHeaders('probe', const {});
  }

  void uninstall() {
    HttpOverrides.global = null;
    _activeServer = null;
  }

  /// 请求进站（_StubRequest.close 时调）：记录后按路径与请求体分诊应答。
  /// 返回（状态码，JSON 负载）。
  (int, String) handle(Uri url, String authorization, String raw) {
    var body = <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // 请求体不是 JSON：按空体处理，照样记录。
    }
    requests.add(_RecordedRequest(url.path, authorization, body));
    return _respond(url.path, body);
  }

  (int, String) _respond(String path, Map<String, dynamic> body) {
    int status = 200;
    Object payload;
    if (path.endsWith('/alpha/decisions') || path.endsWith('/v1/systemone')) {
      if (judgeDecisionsStatus != 200) {
        status = judgeDecisionsStatus;
        payload = jsonEncode({'error': 'mock: 判断路由拒绝（401）'});
      } else {
        payload = jsonEncode({'answers': _decisionsAnswers()});
      }
    } else if (path.endsWith('/chat/completions')) {
      // 同一个端点服务两条路：按 system 消息区分——判断 chat 轮带
      // ChatJudge.system 的固定开头（'strict judgment model'），起草轮是
      // 「即时通讯回复助手」。
      final messages = body['messages'];
      final systemContent = messages is List<dynamic> && messages.isNotEmpty
          ? (messages.first is Map<String, dynamic>
              ? (messages.first as Map<String, dynamic>)['content']
              : null)
          : null;
      final isJudgeChat = systemContent is String &&
          systemContent.contains('strict judgment model');
      payload = isJudgeChat
          ? jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({'answers': _decisionsAnswers()}),
                  },
                },
              ],
            })
          : jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(_draftCandidates())},
                },
              ],
            });
    } else {
      status = 404;
      payload = '{}';
    }
    return (status, payload as String);
  }

  /// 判断（7 题）的标准应答：闲聊、低危、best_action=acknowledge。
  /// acknowledge 对应的 F1 策略偏好是 safe（StrategyOrder.preferred）。
  static Map<String, dynamic> _decisionsAnswers() => {
        'true_intent': {'choice': 'casual_chat', 'confidence': 0.9},
        'danger_level': {'score': 1, 'confidence': 0.8},
        'she_needs': {'choice': 'engagement', 'confidence': 0.7},
        'should_reply_now': {'noul': 0.9, 'confidence': 0.9},
        'best_action': {'choice': 'acknowledge', 'confidence': 0.8},
        'tension_resolved': {'noul': 0.5, 'confidence': 0.5},
        'literal_question': {'noul': 0.5, 'confidence': 0.5},
      };

  /// 起草候选：safe 刻意排第二——成功轮的 F1 提升要把它顶到第一，
  /// 降级轮（无 best_action）必须保持原序，两头都用同一条底稿区分。
  static List<Map<String, dynamic>> _draftCandidates() => [
        {'strategy': 'forward', 'text': '累了就早点休息呀，明天再忙也来得及'},
        {'strategy': 'safe', 'text': '辛苦啦，先去躺会儿吧'},
        {'strategy': 'angle', 'text': '晚饭点了吗？要不要一起点一份'},
      ];
}

class _RecordedRequest {
  const _RecordedRequest(this.path, this.authorization, this.body);

  final String path;
  final String authorization;
  final Map<String, dynamic> body;

  /// 起草 user 提示词（messages 的最后一条，role=user）。
  String get draftUserContent {
    final messages = body['messages'];
    if (messages is! List<dynamic> || messages.isEmpty) return '';
    final last = messages.last;
    if (last is! Map<String, dynamic>) return '';
    return last['content'] as String? ?? '';
  }
}

/// manualOcr 的通道 mock 载荷：一条对方消息（含「蓝鲸」→ 必命中知识库笔记），
/// confidence 1.0 = 高置信快照，走自动分析路径（不挂 G3 确认）。
Map<String, dynamic> _snapshotJson() => {
      'title': '客户群',
      'messages': [
        {'side': 'other', 'text': '蓝鲸项目的质保期到底怎么算？客户刚又来问了'},
      ],
      'confidence': 1.0,
    };

const MethodChannel _controlChannel = MethodChannel('capture_android/control');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final server = _MockModelServer();
  final subs = <StreamSubscription<dynamic>>[];

  setUp(() async {
    // HttpJson 的重试退避是可变静态（测试缝）：401 本就不重试，这里把退避
    // 压成零等待兜底任何 5xx 分支；用完还原生产值。
    HttpJson.retryBackoffMs = 0;
    server.install();
    // manualOcr → 返回快照 JSON 字符串（_snapshotFromEvent 按 String 解析）；
    // showSuggestions → true（悬浮窗推送成功，不触发权限收回分支）。
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_controlChannel, (call) async {
      switch (call.method) {
        case 'manualOcr':
          return jsonEncode(_snapshotJson());
        case 'showSuggestions':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_controlChannel, null);
    server.uninstall();
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    HttpJson.retryBackoffMs = 500;
    server.requests.clear();
    server.judgeDecisionsStatus = 200;
  });

  /// 造一个已注入 KbStore 笔记的会话（#13 链路随降级轮回归钉住）。
  (CaptureSession, UsageStats) makeSession(ValueNotifier<JevConfig> config) {
    final kb = KbStore();
    kb.saveNote(
      const Note(id: 'n1', title: '售后条款', content: '蓝鲸项目的质保期是两年'),
      source: KbSource.manual,
    );
    final usage = UsageStats();
    final session = CaptureSession(
      config: config,
      relationship: ValueNotifier<String>('客户'),
      overlayEnabled: ValueNotifier<bool>(true),
      // fix(#11 P0-N) 的 scenarioId 链路：降级轮必须照常把场景附加段带进
      // 起草提示词（P0 修复不许吃掉 #11 的修复）。
      scenarioId: ValueNotifier<String>('support_agent'),
      knowledgeBase: kb,
      stats: usage,
    );
    return (session, usage);
  }

  group('全新安装（出厂默认配置）：判断路由未配置 → 跳过判断直接起草', () {
    test('起草请求正常构造、候选非空，且全程无 judge 网络调用', () async {
      final (session, usage) =
          makeSession(ValueNotifier<JevConfig>(JevConfig()));
      addTearDown(session.dispose);

      await session.manualOcr();

      final st = session.state.value;
      // 核心流程恢复：候选不再恒空，且不是靠错误卡顶着。
      expect(st.error, isNull, reason: '顶层错误位必须干净——错误卡会顶掉候选');
      expect(st.analysis, isNotNull);
      expect(st.analysis!.error, isNull, reason: '未配置不是失败：不得伪装成判断错误');
      expect(st.analysis!.rankedReplies, hasLength(3));
      // 合成空判断没有 best_action：F1 提升不动作，保持起草原序。
      expect(st.analysis!.bestAction, isNull);
      expect(
        st.analysis!.rankedReplies.map((r) => r.strategy),
        ['forward', 'safe', 'angle'],
      );

      // 网络：只有回复路由被调用，判断路由零请求。
      expect(usage.calls(UsageRoute.reply), greaterThanOrEqualTo(1));
      expect(usage.failures(UsageRoute.reply), 0);
      expect(usage.failures(UsageRoute.judge), 0,
          reason: '未配置的判断路由不得记失败（它压根没被调用）');
      expect(server.requests, isNotEmpty);
      for (final r in server.requests) {
        expect(r.path.endsWith('/chat/completions'), isTrue,
            reason: '只允许回复路由出网，实际请求了 ${r.path}');
      }
      expect(
        server.requests.any((r) =>
            r.path.endsWith('/alpha/decisions') ||
            r.path.endsWith('/v1/systemone')),
        isFalse,
        reason: 'P0 主断言：全新安装不得发出任何判断路由网络调用',
      );

      // 起草请求构造正常：user 提示词完整，且不含判断噪声块。
      final drafts = server.requests.toList();
      expect(drafts, isNotEmpty);
      final user = drafts.first.draftUserContent;
      expect(user, contains('请给出 3 条候选回复。'));
      expect(user, isNot(contains('判断结果（')), reason: '空判断不得给起草提示词引入「看不出×3」噪声块');
    });

    test('#11/#13 链路不回归：场景附加段与知识参考照常进降级轮的起草提示词', () async {
      final (session, _) = makeSession(ValueNotifier<JevConfig>(JevConfig()));
      addTearDown(session.dispose);

      await session.manualOcr();

      final st = session.state.value;
      expect(st.analysis!.rankedReplies, hasLength(3));
      final user = server.requests.first.draftUserContent;
      // fix(#11 P0-N)：scenarioId → support_agent 的 user 附加段。
      expect(user, contains('（客服场景提醒）'));
      // #13 检索注入：知识参考段带来源标注（「蓝鲸」同时出现在对话原文里，
      // 所以必须断言来源标注本身，那个串只有注入能产生）。
      expect(user, contains('知识参考（来源：知识库笔记《售后条款》）'));
      expect(user, contains('蓝鲸项目的质保期是两年'));
      // G1 预览照常产出（预览与发送同源的契约不受降级影响）。
      expect(st.preview, isNotNull);
    });

    test('「换一组」在降级态：盲写重起草、候选保留、错误标注不丢', () async {
      final (session, usage) =
          makeSession(ValueNotifier<JevConfig>(JevConfig()));
      addTearDown(session.dispose);

      await session.manualOcr();
      final before = server.requests.length;
      expect(session.state.value.analysis, isNotNull);

      await session.regenerate();

      final st = session.state.value;
      expect(st.error, isNull);
      expect(st.analysis, isNotNull);
      expect(st.analysis!.rankedReplies, hasLength(3));
      // regenerate 的起草 user 提示词同样不带判断噪声块（与首轮同构）。
      final regenerateDrafts = server.requests.sublist(before);
      expect(regenerateDrafts, isNotEmpty);
      expect(regenerateDrafts.first.draftUserContent, contains('不要重复其中任何一句'),
          reason: 'avoid 名单随「换一组」出门');
      expect(
        regenerateDrafts.first.draftUserContent,
        isNot(contains('判断结果（')),
      );
      expect(usage.failures(UsageRoute.judge), 0);
    });
  });

  group('judge 已配置但调用失败：降级起草 + 错误可见', () {
    test('judge 401 → 候选照常出、错误留在 analysis.error（不静默吞）', () async {
      final config = ValueNotifier<JevConfig>(JevConfig()
        ..judgeBaseUrl = server.judgeBase
        ..judgeModel = 'mock-judge-model');
      server.judgeDecisionsStatus = 401;
      final (session, usage) = makeSession(config);
      addTearDown(session.dispose);

      await session.manualOcr();

      final st = session.state.value;
      // 降级起草：候选非空（P0 的核心诉求——失败不再拦起草）。
      expect(st.analysis, isNotNull);
      expect(st.analysis!.rankedReplies, hasLength(3));
      // 错误可见：留在 state 的可见位置（analysis.error——桌面助手页按它
      // 渲染判断错误卡）；顶层 error 刻意不写（采集页错误卡与候选互斥）。
      expect(st.analysis!.error, isNotNull);
      expect(st.analysis!.error!, isNotEmpty);
      expect(st.error, isNull);
      // 判断路由真的被调用了（judge + 排序轮都打到 /alpha/decisions），且
      // 统计如实记了失败。
      expect(
        server.requests.where((r) => r.path.endsWith('/alpha/decisions')),
        isNotEmpty,
      );
      expect(usage.calls(UsageRoute.judge), greaterThanOrEqualTo(1));
      expect(usage.failures(UsageRoute.judge), greaterThanOrEqualTo(1));
      // 降级轮的起草提示词同样不带判断噪声块。
      final user = server.requests
          .firstWhere((r) => r.path.endsWith('/chat/completions'))
          .draftUserContent;
      expect(user, isNot(contains('判断结果（')));
    });

    test('judge 401 的降级态下「换一组」：候选保留、错误标注不丢', () async {
      final config = ValueNotifier<JevConfig>(JevConfig()
        ..judgeBaseUrl = server.judgeBase
        ..judgeModel = 'mock-judge-model');
      server.judgeDecisionsStatus = 401;
      final (session, _) = makeSession(config);
      addTearDown(session.dispose);

      await session.manualOcr();
      final before = server.requests.length;
      await session.regenerate();

      final st = session.state.value;
      expect(st.analysis, isNotNull);
      expect(st.analysis!.error, isNotNull, reason: '写回用原对象，错误标注不能丢');
      expect(st.analysis!.rankedReplies, hasLength(3));
      expect(server.requests.length, greaterThan(before));
    });
  });

  group('judge 已配置且成功：非降级路径零回归', () {
    test('判断字段进 state 与起草提示词，F1 策略提升照常生效', () async {
      final config = ValueNotifier<JevConfig>(JevConfig()
        ..judgeBaseUrl = server.judgeBase
        ..judgeModel = 'mock-judge-model');
      final (session, usage) = makeSession(config);
      addTearDown(session.dispose);

      await session.manualOcr();

      final st = session.state.value;
      expect(st.error, isNull);
      expect(st.analysis!.error, isNull);
      // 判断字段如实落到 state。
      expect(st.analysis!.trueIntent?.choice, 'casual_chat');
      expect(st.analysis!.bestAction?.choice, 'acknowledge');
      // 判断真的进了起草提示词（非「两头都没有」的假绿）。
      final user = server.requests
          .firstWhere((r) => r.path.endsWith('/chat/completions'))
          .draftUserContent;
      expect(user, contains('判断结果（'));
      expect(user, contains('只是日常闲聊或打趣'));
      // F1：best_action=acknowledge → 策略偏好 safe，顶到第一。
      expect(st.analysis!.rankedReplies.first.strategy, 'safe');
      expect(usage.failures(UsageRoute.judge), 0);
    });
  });

  group('judgeProvider=跟随回复路由', () {
    test('judge 调用落点就是回复端点：Key 随回复路由、模型随 replyModel', () async {
      final config = ValueNotifier<JevConfig>(JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        ..replyBaseUrl = server.replyBase
        ..replyKey = 'reply-key'
        ..replyModel = 'mock-reply-model'
        ..judgeModel = '');
      final (session, _) = makeSession(config);
      addTearDown(session.dispose);

      await session.manualOcr();

      final st = session.state.value;
      // 判断 chat 轮成功应答：判断字段落到 state，候选照常。
      expect(st.analysis!.error, isNull);
      expect(st.analysis!.trueIntent?.choice, 'casual_chat');
      expect(st.analysis!.rankedReplies, isNotEmpty);

      // 找出判断 chat 轮（system 带 ChatJudge 固定开头）的请求。
      final judgeReqs = server.requests.where((r) {
        final messages = r.body['messages'];
        if (messages is! List<dynamic> || messages.isEmpty) return false;
        final first = messages.first;
        return first is Map<String, dynamic> &&
            first['content'] is String &&
            (first['content'] as String).contains('strict judgment model');
      }).toList();
      expect(judgeReqs, isNotEmpty, reason: '判断必须作为 chat 轮发到回复端点');
      for (final r in judgeReqs) {
        expect(r.path, '/v1/chat/completions', reason: '跟随回复路由：端点即回复端点');
        expect(r.authorization, 'Bearer reply-key',
            reason: '密钥随回复路由（effectiveJudgeKey）');
        expect(r.body['model'], 'mock-reply-model',
            reason: 'judgeModel 留空沿用回复模型（effectiveJudgeModel）');
      }
    });
  });
}

/// ---------------------------------------------------------------- 替身管道
/// 以下五个类与 capture_page_scenario_wiring_test.dart 的同名结构同源（复制
/// 而非共享：test/ 无共享库，两文件各自成套），只按本文件需要改动两处——
/// close() 把（状态码, 负载）从 [_MockModelServer.handle] 带回来；headers 的
/// value() 不区分大小写（真 HttpHeaders 的语义，Authorization 记录用）。

/// 当前替身（install 时设定、uninstall 时清空）。HttpJson 的静态 `_client`
/// 是 isolate 单份：替换身对象经此指针按用例路由，断言互不串。
_MockModelServer? _activeServer;

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
  Future<HttpClientResponse> close() {
    final (status, payload) = _activeServer!.handle(
      url,
      headers.value('authorization') ?? '',
      _body.toString(),
    );
    return Future.value(_StubResponse(status, payload));
  }

  @override
  void abort([Object? cause, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubHeaders implements HttpHeaders {
  final Map<String, String> _map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map[name.toLowerCase()] = '$value';

  @override
  String? value(String name) => _map[name.toLowerCase()];

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
