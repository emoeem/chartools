import 'package:chartools_core/src/pipeline/reply_cache_key.dart';
import 'package:test/test.dart';

/// 对拍旧仓库 `ReplyCacheKeyTest.kt` 的思路。
///
/// 键里漏一个分量不会报错，只会「改了输入、回复没变」——用户以为功能坏了，
/// 我们连日志都没有。所以这里对**每一个**分量单独做一次变异：改它，键必须变。
///
/// 最要紧的是「style 变了键就变」：专家库全靠换 `style` 生效，它一旦从键里
/// 掉出去，换专家就等于换了个寂寞，而且测不出来。
void main() {
  const base = _In();

  test('同样的输入得到逐字相同的键', () {
    expect(const _In().key(), base.key());
  });

  test('style 变了键就变', () {
    final a = const _In(style: '主题：职场').key();
    final b = const _In(style: '主题：恋爱').key();
    expect(a, isNot(b));
  });

  test('十五个分量逐个变异，键都要变', () {
    // params 捆绑包按子字段拆三份变异（与 Kotlin 参考逐字一致）。
    final pLang = 'en|standard|0.8|0.0|0.0|false|review-model';
    final pTemp = 'follow|standard|0.9|0.0|0.0|false|review-model';
    final pReview = 'follow|standard|0.8|0.0|0.0|true|review-model';
    final mutated = <String, _In>{
      'title': base.copyWith(title: 'T2'),
      'signature': base.copyWith(sig: 'S2'),
      'relationship': base.copyWith(rel: 'R2'),
      'style': base.copyWith(style: 'ST2'),
      'replyModel': base.copyWith(model: 'M2'),
      'count': base.copyWith(count: 4),
      'avoid': base.copyWith(avoid: const ['x', 'y']),
      'ctxKey': base.copyWith(ctx: 'C2'),
      'ledgerKey': base.copyWith(ledger: 'L2'),
      'judgmentKey': base.copyWith(judgment: 'J2'),
      'intensity': base.copyWith(intensity: 'SOFT'),
      'params-语言': base.copyWith(params: pLang),
      'params-温度': base.copyWith(params: pTemp),
      'params-复查': base.copyWith(params: pReview),
      // fix(#11 P0-N)：场景 id 进键——场景变了缓存必须作废（第 15 个分量）。
      'scenarioId': base.copyWith(scenarioId: 'support_agent'),
    };
    // 分量数写死：以后往 reply 里加了新参数却忘了进键，这条会红。
    expect(mutated.length, 15);
    mutated.forEach((name, input) {
      expect(base.key(), isNot(input.key()), reason: '分量 [$name] 没进键');
    });
  });

  test('字段边界不会串味', () {
    // "ab" + "c" 必须区别于 "a" + "bc"：靠分隔符，不靠拼接巧合。
    expect(
      const _In(sig: 'ab', rel: 'c').key(),
      isNot(const _In(sig: 'a', rel: 'bc').key()),
    );
    expect(
      const _In(style: 'ab').key(),
      isNot(const _In(style: 'a', rel: 'bR').key()),
    );
    // title 也一样：标题 "ab" 消息 "c" 不能命中标题 "a" 消息 "bc" 的缓存。
    expect(
      const _In(title: 'ab', sig: 'c').key(),
      isNot(const _In(title: 'a', sig: 'bc').key()),
    );
  });

  test('avoid 多条与单条不同，空列表与含空串不同', () {
    expect(
      const _In(avoid: ['x']).key(),
      isNot(const _In(avoid: ['x', '']).key()),
    );
    expect(
      const _In(avoid: <String>[]).key(),
      isNot(const _In(avoid: ['']).key()),
    );
  });

  test('avoid 长度前缀防住分隔符拼接撞车', () {
    // 只按分隔符拼，["a\x1fb"] 与 ["a", "b"] 会拼出同一串（reply_cache_key.dart
    // 注释里的原始反例）；长度前缀让两者必然分开：'3:a\x1fb' vs '1:a\x1f1:b'。
    expect(
      const _In(avoid: ['a\u001fb']).key(),
      isNot(const _In(avoid: ['a', 'b']).key()),
    );
  });

  test('场景变了键必须变（fix(#11 P0-N)：scenarioId 变 → 键变）', () {
    // 场景附加段进起草提示词：用户把「客服坐席」换成「外语陪练」，缓存里
    // 旧场景的候选必须作废，不能同键命中。
    final support = const _In(scenarioId: 'support_agent').key();
    final learning = const _In(scenarioId: 'language_learning').key();
    expect(support, isNot(learning));

    // 同一个场景两次构造，键逐字相同（缓存命中的前提）。
    expect(
      const _In(scenarioId: 'support_agent').key(),
      const _In(scenarioId: 'support_agent').key(),
    );

    // 空串（未选场景）与任一场景互不相同；默认场景 chat_copilot 的附加段是
    // 空串、提示词与无场景一致，但它与空串是两个键——命中哪个都不串味。
    expect(const _In().key(), isNot(support));
    expect(
      const _In(scenarioId: '').key(),
      isNot(const _In(scenarioId: 'chat_copilot').key()),
    );

    // 键尾的空分量不会把「无场景」和「场景正文撞出同一串」：分隔符隔开，
    // 'support_agent' 不可能与前面的分量拼接巧合出空串键。
    expect(
      const _In(ctx: 'C\u001e').key(),
      isNot(const _In().key()),
    );
  });

  test('判断键跟着判断路由走', () {
    final a = ReplyCacheKey.judge(
      title: 'T',
      signature: 'S',
      relationship: 'R',
      judgeModel: 'judge-1',
      judgeProtocol: 'openai',
      ctxKey: 'C',
    );
    final b = ReplyCacheKey.judge(
      title: 'T',
      signature: 'S',
      relationship: 'R',
      judgeModel: 'judge-2',
      judgeProtocol: 'openai',
      ctxKey: 'C',
    );
    final c = ReplyCacheKey.judge(
      title: 'T',
      signature: 'S',
      relationship: 'R',
      judgeModel: 'judge-1',
      judgeProtocol: 'anthropic',
      ctxKey: 'C',
    );
    final d = ReplyCacheKey.judge(
      title: 'T2',
      signature: 'S',
      relationship: 'R',
      judgeModel: 'judge-1',
      judgeProtocol: 'openai',
      ctxKey: 'C',
    );
    expect(a, isNot(b));
    expect(a, isNot(c));
    expect(a, isNot(d));
    expect(
      a,
      ReplyCacheKey.judge(
        title: 'T',
        signature: 'S',
        relationship: 'R',
        judgeModel: 'judge-1',
        judgeProtocol: 'openai',
        ctxKey: 'C',
      ),
    );
  });

  test('判断键六个分量逐个变异，键都要变', () {
    // 与 reply 侧那条互为镜像：judge 的 6 个分量里 judgeModel / judgeProtocol /
    // title 在上一条有对照，但 signature / relationship / ctxKey 此前没有
    // 单独变异——键里少一个分量的表现是不报错、只串味（本文件头注释），所以
    // 六个都钉。分量数写死：judge() 往签名里加参数却漏进 join 时，这条先红。
    String judgeOf({
      String title = 'T',
      String signature = 'S',
      String relationship = 'R',
      String judgeModel = 'judge-1',
      String judgeProtocol = 'openai',
      String ctxKey = 'C',
    }) =>
        ReplyCacheKey.judge(
          title: title,
          signature: signature,
          relationship: relationship,
          judgeModel: judgeModel,
          judgeProtocol: judgeProtocol,
          ctxKey: ctxKey,
        );

    final base = judgeOf();
    final mutated = <String, String>{
      'title': judgeOf(title: 'T2'),
      'signature': judgeOf(signature: 'S2'),
      'relationship': judgeOf(relationship: 'R2'),
      'judgeModel': judgeOf(judgeModel: 'judge-2'),
      'judgeProtocol': judgeOf(judgeProtocol: 'anthropic'),
      'ctxKey': judgeOf(ctxKey: 'C2'),
    };
    expect(mutated.length, 6);
    mutated.forEach((name, key) {
      expect(base, isNot(key), reason: '判断键分量 [$name] 没进键');
    });
  });

  test('回复键与判断键不会互相命中', () {
    // 两个 LRU 分开存，但键本身也不该长得一样：串了就是把判断当候选回复用。
    final replySide = const _In(
      title: 'T',
      sig: 'S',
      rel: 'R',
      model: 'M',
      ctx: 'C',
      style: 'P',
    ).key();
    expect(
      ReplyCacheKey.judge(
        title: 'T',
        signature: 'S',
        relationship: 'R',
        judgeModel: 'M',
        judgeProtocol: 'P',
        ctxKey: 'C',
      ),
      isNot(replySide),
    );
  });
}

/// 基线输入与逐字段变异（对应 Kotlin 侧的 `In` data class，默认值逐字段一致）。
class _In {
  const _In({
    this.title = 'T',
    this.sig = 'S',
    this.rel = 'R',
    this.style = 'ST',
    this.model = 'M',
    this.count = 3,
    this.avoid = const ['x'],
    this.ctx = 'C',
    this.ledger = 'L',
    this.judgment = 'J',
    this.intensity = 'AUTO',
    this.params = 'follow|standard|0.8|0.0|0.0|false|review-model',
    this.scenarioId = '',
  });

  final String title;
  final String sig;
  final String rel;
  final String style;
  final String model;
  final int count;
  final List<String> avoid;
  final String ctx;
  final String ledger;
  final String judgment;
  final String intensity;
  final String params;

  /// fix(#11 P0-N)：场景 id 分量（默认空串 = 无场景，与接入前同构）。
  final String scenarioId;

  String key() => ReplyCacheKey.reply(
        title: title,
        signature: sig,
        relationship: rel,
        style: style,
        replyModel: model,
        count: count,
        avoid: avoid,
        ctxKey: ctx,
        ledgerKey: ledger,
        judgmentKey: judgment,
        intensity: intensity,
        params: params,
        scenarioId: scenarioId,
      );

  _In copyWith({
    String? title,
    String? sig,
    String? rel,
    String? style,
    String? model,
    int? count,
    List<String>? avoid,
    String? ctx,
    String? ledger,
    String? judgment,
    String? intensity,
    String? params,
    String? scenarioId,
  }) =>
      _In(
        title: title ?? this.title,
        sig: sig ?? this.sig,
        rel: rel ?? this.rel,
        style: style ?? this.style,
        model: model ?? this.model,
        count: count ?? this.count,
        avoid: avoid ?? this.avoid,
        ctx: ctx ?? this.ctx,
        ledger: ledger ?? this.ledger,
        judgment: judgment ?? this.judgment,
        intensity: intensity ?? this.intensity,
        params: params ?? this.params,
        scenarioId: scenarioId ?? this.scenarioId,
      );
}
