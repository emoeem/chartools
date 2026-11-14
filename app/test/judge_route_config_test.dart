/// P0 判断路由降级的配置与门测试（判断路由默认关闭 + 优雅降级 + 可配）。
///
/// 钉住四层契约：
/// 1. [JevConfig.judgeRouteConfigured] —— 「判断路由是否已配置」的**唯一判据**
///    （capture_session 与 JudgeClient 的未配置门都调它）。核心落点：全新安装
///    （judgeProvider='jev' + judgeBaseUrl=''）必须判 false，这正是 P0
///    「judgeEndpoint 产物是相对地址 → JudgeClient 必炸 → 候选恒空」的根因门。
/// 2. 「跟随回复路由」档（judgeProvider='follow_reply'）：端点/协议/密钥/模型
///    四项推导全部随回复路由，非跟随档的推导逐字节不变（不改既有请求）。
/// 3. [JudgeClient] 未配置门：judge 不发网络请求返回无错误空判断、rank 原序
///    返回——任何调用方（桌面页/analyze）都不会再因判断未配置拦起草。
/// 4. [JudgeClient.usableJudgment] —— 「判断不可用 → 盲写」的唯一准入判定，
///    失败/空判断不得把「看不出×3」噪声块带进起草提示词。
///
/// 本文件为新增（不改既有测试文件）。纯单测：除「已配置但连不通」一例直连
/// 本机保留端口外，不发任何网络请求。
library;

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter_test/flutter_test.dart';

ChatSnapshot _snapshot() =>
    const ChatSnapshot(messages: [Msg(side: 'other', text: '今天好累啊')]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // HttpJson 的重试退避是可变静态（测试缝）：连不通的用例里三次退避压成
  // 零等待，用完还原生产值。
  setUp(() => HttpJson.retryBackoffMs = 0);
  tearDown(() => HttpJson.retryBackoffMs = 500);

  group('JevConfig.judgeRouteConfigured（唯一判据）', () {
    test('全新安装（出厂默认：jev + 空 base）→ 未配置：相对地址发不出 POST', () {
      final c = JevConfig();
      // 根因对照：judgeEndpoint 产物是相对地址（旧契约原样保留，不抛），
      // HttpClient.openUrl 对它直接抛 ArgumentError——P0 里 JudgeClient 必炸
      // 的那条路。判据必须在门口把它拦成「未配置」。
      expect(c.judgeEndpoint(), '/alpha/decisions');
      expect(c.judgeRouteConfigured(), isFalse);
    });

    test('jev + 配了地址 → 已配置', () {
      final c = JevConfig()..judgeBaseUrl = 'https://judge.example.com';
      expect(c.judgeRouteConfigured(), isTrue);
    });

    test('chat 协议 base 空 → 已配置：回退 DeepSeek 官方宿主（既有契约）', () {
      // 两种来源都算 chat：显式协议 / deepseek provider 的推断。
      expect(
        (JevConfig()..judgeProtocol = 'chat').judgeRouteConfigured(),
        isTrue,
      );
      expect(
        (JevConfig()..judgeProvider = 'deepseek').judgeRouteConfigured(),
        isTrue,
      );
      expect(
        (JevConfig()..judgeProvider = 'deepseek').judgeEndpoint(),
        'https://api.deepseek.com/chat/completions',
      );
    });

    test('custom + 裸域名（无 scheme）→ 未配置：那种地址本来就发不出 POST', () {
      final c = JevConfig()
        ..judgeProvider = 'custom'
        ..judgeBaseUrl = 'example.com/api/decide';
      expect(c.judgeRouteConfigured(), isFalse);
    });

    test('custom + 完整 https 地址 → 已配置（旧契约原样返回用户地址）', () {
      final c = JevConfig()
        ..judgeProvider = 'custom'
        ..judgeBaseUrl = 'https://gw.example.com/decide';
      expect(c.judgeEndpoint(), 'https://gw.example.com/decide');
      expect(c.judgeRouteConfigured(), isTrue);
    });

    test('跟随回复路由：回复地址有值 → 已配置；回复地址被清空 → 同样未配置', () {
      final c = JevConfig()..judgeProvider = JevConfig.judgeProviderFollowReply;
      // 出厂默认 replyBaseUrl 是 openrouter → 判断跟着回复走，恒已配置。
      expect(c.judgeRouteConfigured(), isTrue);
      // 用户把回复地址也清空了：判断与回复同生共死，一起算未配置。
      expect(
        (c..replyBaseUrl = '').judgeRouteConfigured(),
        isFalse,
      );
    });
  });

  group('跟随回复路由档（follow_reply）的推导', () {
    test('judgeEndpoint 复用回复端点（含剥尾部斜杠），非跟随档不受影响', () {
      final c = JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        ..judgeBaseUrl = 'https://judge.example.com'
        ..replyBaseUrl = 'https://reply.example.com/v1/';
      expect(
          c.judgeEndpoint(), 'https://reply.example.com/v1/chat/completions');
      expect(
          c.replyEndpoint(), 'https://reply.example.com/v1/chat/completions');

      // 非跟随档：judgeEndpoint 仍走自己的 base（jev + /alpha/decisions）。
      final d = JevConfig()..judgeBaseUrl = 'https://judge.example.com';
      expect(d.judgeEndpoint(), 'https://judge.example.com/alpha/decisions');
    });

    test('协议强制 chat：存档残留的显式 judgeProtocol 不把跟随档拖回 decisions', () {
      final c = JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        // 「跟随回复路由」之前用户显式选过 decisions 协议：换档必须生效。
        ..judgeProtocol = 'decisions';
      expect(c.effectiveJudgeProtocol(), 'chat');
    });

    test('密钥随回复路由：replyKey 优先，replyKey 空落到 judgeKey（既有链）', () {
      final c = JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        ..replyKey = 'reply-key'
        ..judgeKey = 'judge-key';
      expect(c.effectiveJudgeKey(), 'reply-key');

      final d = JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        ..replyKey = ''
        ..judgeKey = 'judge-key';
      expect(d.effectiveJudgeKey(), 'judge-key');
    });

    test('模型：judgeModel 显式值优先；留空沿用 replyModel（与复查/润色同模式）', () {
      final c = JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        ..judgeModel = 'explicit-judge-model'
        ..replyModel = 'reply-model';
      expect(c.effectiveJudgeModel(), 'explicit-judge-model');

      final d = JevConfig()
        ..judgeProvider = JevConfig.judgeProviderFollowReply
        ..judgeModel = ''
        ..replyModel = 'reply-model';
      expect(d.effectiveJudgeModel(), 'reply-model');
    });

    test('非跟随档不引入新回退：key/model 原样返回，请求字节不变', () {
      final c = JevConfig()
        ..judgeKey = 'judge-key'
        ..judgeModel = ''
        ..replyModel = 'reply-model';
      // 判空不沿用回复模型——旧仓库没有这条规则，移植版请求体必须原样。
      expect(c.effectiveJudgeKey(), 'judge-key');
      expect(c.effectiveJudgeModel(), '');
    });
  });

  group('JudgeClient 未配置门（不发网络请求）', () {
    test('judge：未配置 → 无错误的空判断对象（无 best_action，字段全空）', () async {
      final analysis =
          await JudgeClient(JevConfig()).judge(_snapshot(), '朋友', ctx: null);
      // 无错误是关键：调用方（capture_session / 桌面页）以 error == null 判定
      // 「判断阶段没拦路」，候选照常起草——错误会触发「已配置但失败」的
      // 降级语义，未配置不该被当成失败。
      expect(analysis.error, isNull);
      expect(analysis.bestAction, isNull);
      expect(analysis.trueIntent, isNull);
      expect(analysis.dangerLevel, isNull);
      expect(analysis.sheNeeds, isNull);
      expect(analysis.shouldReplyNow, isNull);
      expect(analysis.rankedReplies, isEmpty);
    });

    test('rank：未配置 → 按输入顺序原样返回，prob 0、ranked false（不编概率）', () async {
      final scored = await JudgeClient(JevConfig()).rank(
        _snapshot(),
        '朋友',
        ['候选甲', '候选乙', '候选丙'],
      );
      expect(scored.map((r) => r.text), ['候选甲', '候选乙', '候选丙']);
      expect(scored.every((r) => r.prob == 0.0), isTrue);
      expect(scored.every((r) => !r.ranked), isTrue);
    });

    test('已配置但连不通 → 既有语义：Analysis.error 带错误信息（调用方降级起草）', () async {
      final c = JevConfig()..judgeBaseUrl = 'http://127.0.0.1:1'; // 保留端口，连接必被拒。
      final analysis = await JudgeClient(c).judge(_snapshot(), '朋友');
      expect(analysis.error, isNotNull);
      // 失败判断不得被误当成「没判断」：错误对象里没有任何判断字段。
      expect(analysis.bestAction, isNull);
      expect(analysis.trueIntent, isNull);
    });
  });

  group('JudgeClient.usableJudgment（判断不可用 → 盲写）', () {
    test('null / 失败（error）/ 空对象 → 一律 null：不给起草提示词塞判断噪声', () {
      expect(JudgeClient.usableJudgment(null), isNull);
      expect(
        JudgeClient.usableJudgment(
          const Analysis(latencyMs: 12, error: '判断接口请求失败'),
        ),
        isNull,
      );
      // 未配置合成的空对象与 chat 协议答案全缺的空对象：都没有判断信号。
      expect(JudgeClient.usableJudgment(const Analysis(latencyMs: 0)), isNull);
    });

    test('有判断信号（任一字段非空）→ 原样透传，不复制不改写', () {
      final partial = const Analysis(
        shouldReplyNow: 0.9,
        latencyMs: 5,
      );
      expect(JudgeClient.usableJudgment(partial), same(partial));

      final full = Analysis(
        trueIntent: const Choice(choice: 'casual_chat', confidence: 0.9),
        dangerLevel: const Score(score: 1, confidence: 0.8, maxLevel: 9),
        bestAction: const Choice(choice: 'acknowledge', confidence: 0.8),
        latencyMs: 5,
      );
      expect(JudgeClient.usableJudgment(full), same(full));
    });
  });
}
