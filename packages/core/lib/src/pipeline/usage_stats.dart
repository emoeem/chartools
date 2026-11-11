/// 四条模型路由的使用统计（C9）：judge / reply / review / polish 各自的调用
/// 次数、失败次数、缓存命中次数，累计与「本次会话」两个口径。
///
/// 接线契约（跨文件，供采集流水线 / 桌面助手侧照做）：
///  - `JevClient(config, stats: store.usage)`：app 层把 [UsageStats] 这一份
///    实例传进 JevClient —— 打点方（pipeline 各门面方法）与读数方（设置页
///    统计卡、重置按钮）读写同一个对象。stats 缺省（null）= 完全不打点，
///    行为与统计接入前一致，现有调用方与测试零改动。
///  - 一个 [UsageStats] 内部同时维护两个口径：累计（跨启动持久化，[toJson]
///    序列化的就是它）与本次会话（运行态，每次启动从零）。打点方法同时
///    累加两个口径，读数按 `session:` 参数选口径。
///
/// 边界与不变量：
///  - 打点发生在 JevClient 门面层（jev_client.dart 的 _tracked 包装），不进
///    HTTP 层、不进提示词 —— 打点不改变任何请求字节；
///  - 本文件只依赖 Dart 核心库，不依赖 app、不依赖 Flutter；
///  - 失败次数 ⊆ 调用次数：调用次数由 [recordCall] 记（失败也先记调用），
///    [recordFailure] 只补失败那一笔，顺序由打点方保证；
///  - 缓存命中不产生调用：judge / draft 缓存直接返回缓存值，不走网络，所以
///    命中数不进调用数。review / polish 两条路由没有缓存，命中数恒为 0。
///
/// 统计是用户自己的数据（p0-plan ②「可查看/修改/删除自己的偏好」）：设置页
/// 统计卡展示两个口径的数字，重置按钮清零并随下次设置写盘持久化。
library;

/// 被统计的四条模型路由（C9）。序列化用 [name] 当 JSON 键（随枚举稳定），
/// 中文文案在 [label]。
enum UsageRoute {
  /// 判断路由：7 问判断（JudgeClient.judge）与候选排序（JudgeClient.rank）。
  judge,

  /// 回复路由：起草（draft / draftOnly / draftStream）与手动精修（refine）。
  reply,

  /// 复查路由：S1 证据复查（ReplyClient.review）。
  review,

  /// 润色路由：linter 命中与复查驳回候选的自动重写（rewriteOnPolishRoute）。
  polish;

  /// 设置页统计卡上的路由名。
  String get label => switch (this) {
        UsageRoute.judge => '判断',
        UsageRoute.reply => '回复',
        UsageRoute.review => '复查',
        UsageRoute.polish => '润色',
      };
}

/// 一条路由在一种口径下的三个计数。由 [UsageStats] 私有持有并打点，外部只经
/// [UsageStats] 的读数方法取值。
class _Counters {
  int calls = 0;
  int failures = 0;
  int cacheHits = 0;

  void addCall() => calls++;

  void addFailure() => failures++;

  void addCacheHit() => cacheHits++;

  void reset() {
    calls = 0;
    failures = 0;
    cacheHits = 0;
  }

  Map<String, dynamic> toJson() =>
      {'calls': calls, 'failures': failures, 'cacheHits': cacheHits};

  /// 存档灌入：缺键 / 类型不符一律落 0（坏形状不清空别的路由），失败数夹回
  /// [0, calls] 保住「失败 ⊆ 调用」的不变量 —— 手改过的存档不该画出比调用
  /// 还多的失败。
  void loadJson(Object? json) {
    if (json is! Map) return;
    calls = _count(json['calls']);
    failures = _count(json['failures']);
    cacheHits = _count(json['cacheHits']);
    if (failures > calls) failures = calls;
  }

  static int _count(Object? v) => v is int && v >= 0 ? v : 0;
}

/// 四条路由 × 两个口径的使用统计。可变对象：打点方直接改内部计数，读数方
/// 经 calls/failures/cacheHits 取当前值 —— 没有快照与通知机制，统计卡在
/// 打开或重置时读一次（见 app 设置页统计卡的注释）。
class UsageStats {
  UsageStats();

  /// 累计口径：跨启动持久化，[toJson] 序列化它、[restore] 恢复它。
  final Map<UsageRoute, _Counters> _cumulative = {
    for (final route in UsageRoute.values) route: _Counters(),
  };

  /// 本次会话口径：运行态，每次启动从零开始，随打点同步累加，[reset] 一并
  /// 清零。不进存档 —— 它的定义就是启动清零。
  final Map<UsageRoute, _Counters> _session = {
    for (final route in UsageRoute.values) route: _Counters(),
  };

  // ------------------------------------------------------------------ 打点

  /// 记一次真实调用（缓存命中不走这里 —— 命中是 [recordCacheHit]）。失败也
  /// 先记调用：调用次数是「发起过的调用数」，失败次数是其中没产出可用结果
  /// 的那部分。
  void recordCall(UsageRoute route) {
    _cumulative[route]!.addCall();
    _session[route]!.addCall();
  }

  /// 补记一次失败（调用本身已由 [recordCall] 记过，这里不再加调用数）。
  /// 判断路由的 Analysis.error、各路由的 HTTP 异常与「响应成功但不可解析」
  /// 都算失败；用户取消（RequestCancelledException）不算 —— 见 jev_client
  /// 各打点行。
  void recordFailure(UsageRoute route) {
    _cumulative[route]!.addFailure();
    _session[route]!.addFailure();
  }

  /// 记一次缓存命中（judge / draft 两处有缓存语义的点）。命中不发网络请求，
  /// 不进调用次数。
  void recordCacheHit(UsageRoute route) {
    _cumulative[route]!.addCacheHit();
    _session[route]!.addCacheHit();
  }

  // ------------------------------------------------------------------ 读数

  /// [route] 的调用次数；`session: true` 读本次会话口径，否则累计。
  int calls(UsageRoute route, {bool session = false}) =>
      _pick(route, session).calls;

  /// [route] 的失败次数（⊆ 调用次数），口径同 [calls]。
  int failures(UsageRoute route, {bool session = false}) =>
      _pick(route, session).failures;

  /// [route] 的缓存命中数（只有 judge / reply 两路可能非零），口径同 [calls]。
  int cacheHits(UsageRoute route, {bool session = false}) =>
      _pick(route, session).cacheHits;

  _Counters _pick(UsageRoute route, bool session) =>
      session ? _session[route]! : _cumulative[route]!;

  // ------------------------------------------------------------ 重置 / 存取

  /// 清零两个口径（设置页「重置统计」按钮）。累计清零后的落盘由 app 层的
  /// SettingsStore.save 负责；会话口径本是运行态，一并清零让卡片上两组数字
  /// 与按钮语义一致。
  void reset() {
    for (final c in _cumulative.values) {
      c.reset();
    }
    for (final c in _session.values) {
      c.reset();
    }
  }

  /// 累计口径的存档形状：每条路由一个 `{"calls","failures","cacheHits"}`
  /// 对象，键用 [UsageRoute.name]。本次会话口径不进存档。
  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final route in UsageRoute.values)
          route.name: _cumulative[route]!.toJson(),
      };

  /// 从存档恢复累计口径（只认 [UsageRoute.name] 键，缺键落 0，多余键忽略）。
  factory UsageStats.fromJson(Map<String, dynamic> json) {
    final stats = UsageStats();
    stats.restore(json);
    return stats;
  }

  /// 就地恢复累计口径：app 层的 load 用它而不是换实例 —— store.usage 的引用
  /// 从构造起就交给 JevClient 与统计卡，保持身份稳定，不存在「恢复前构造的
  /// JevClient 打到旧实例上」的窗口。会话口径不动（启动即清零）。
  void restore(Map<String, dynamic>? json) {
    if (json == null) return;
    for (final route in UsageRoute.values) {
      _cumulative[route]!.loadJson(json[route.name]);
    }
  }
}
