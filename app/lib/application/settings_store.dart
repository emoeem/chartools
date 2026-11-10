import 'dart:convert';

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置持久化：模型路由配置（[JevConfig]）+ 关系描述 + 悬浮窗开关 + 采集应用
/// 黑名单 + 候选展示模式 + 引导完成标记。非敏感字段整包序列化成一个 JSON
/// 字符串，经 shared_preferences 的 setString 存取；API Key（replyKey/judgeKey）
/// 例外——单独存 flutter_secure_storage 安全区（Android 走 Keystore、Windows
/// 走 DPAPI），明文不再进 shared_preferences（p0-plan F2，见 [_secureReplyKey]）。
///
/// 对应旧仓库 `core/Prefs.kt` 里的三组偏好：
/// - config 全部字段：旧仓库逐项散在 SharedPreferences（路由、文风、采样……），
///   字段语义与默认值 core 已在 [JevConfig] 逐条注释，toJson/fromJson 负责
///   round trip，这里只管整包存取，不重复字段级规则。
/// - relationship：Prefs.kt:317-319，键 `"relationship"`，默认 `"朋友"`
///   （Prefs.kt:675 `DEFAULT_REL`）；旧 setter 不 trim，修剪留给使用方
///   （采集流水线用前自行 trim），这里同样原样存取。
/// - 悬浮窗开关：Prefs.kt:374-378 的 `enabled`（键 `"enabled"`，默认开），
///   即「显示悬浮窗 + 跑分析」的总开关。悬浮窗本轮已移植：[relationship] 与
///   [overlayEnabled] 由采集侧直接消费——CaptureSession 构造注入这两个
///   notifier（见 application/capture_session.dart），采集页与设置页写的是
///   同一份值，没有第二轨。
///
/// 其余字段是本仓库新增（旧仓库没有对应项）：
/// - [blockedPackages]：采集应用黑名单（p0-plan ⑦，隐私底线清单）。
/// - [displayMode]：候选展示模式（p0-plan B8，主推一张大卡或全部展开）。
/// - [onboarded]：首次运行引导完成标记（p0-plan ②，引导页写、主入口读）。
/// - [scenarioId]：引导第一步记住的场景（p0-plan ②「单选并记住」）。
class SettingsStore {
  SettingsStore();

  /// shared_preferences 里的存档键：一个 key 存整包 JSON。旧仓库是每项
  /// 一个 key；整包存取让读写始终对称，也给 [JevConfig.toJson] 一个位置。
  static const String _storageKey = 'settings';

  // ---------------------------------------------------------------- 安全区

  /// 安全区里 replyKey 的键。明文 key 的唯一落盘点（p0-plan F2）：
  /// [JevConfig.toJson] 写出的存档里没有这两个字段，shared_preferences 里
  /// 因此不再出现 key 明文。
  static const String _secureReplyKey = 'config.replyKey';

  /// 安全区里 judgeKey 的键，同上。
  static const String _secureJudgeKey = 'config.judgeKey';

  /// flutter_secure_storage 门面。Android 走 Keystore，Windows 走 DPAPI，
  /// 均为系统级加密，插件内部处理，这里不传任何自定义选项。
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  /// 读安全区的一个键；平台通道不可用（测试环境、通道未挂）返回 null——
  /// key 读不到按「没存过」处理，不能挡住其余字段的加载。
  Future<String?> _readSecure(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }

  /// 写安全区的一个键；空值改为删除（安全区里不留空串密钥）。失败原样抛出：
  /// [save] 的调用方（设置页）会把异常显示为「写盘失败」，静默吞掉会让旧 key
  /// 留在安全区、下次启动复活覆盖用户刚改的新 key。
  Future<void> _writeSecure(String key, String value) async {
    if (value.isEmpty) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  // ------------------------------------------------------------- 内存态字段

  /// 模型路由配置的内存态：设置页改它，连通性测试与采集流水线读它。
  final ValueNotifier<JevConfig> config = ValueNotifier(JevConfig());

  /// 关系描述（进提示词与判断 state 的那个字段）。默认值与旧仓库
  /// DEFAULT_REL（Prefs.kt:675）一致；采集流水线（CaptureSession）直接读
  /// 这份 notifier，采集页与设置页写它。
  final ValueNotifier<String> relationship = ValueNotifier('朋友');

  /// 悬浮窗总开关，默认开（Prefs.kt:376）；采集流水线（CaptureSession）直接
  /// 读这份 notifier——开关关掉即收起悬浮窗，打开后下一批建议落地时弹出。
  final ValueNotifier<bool> overlayEnabled = ValueNotifier(true);

  /// 采集应用黑名单（p0-plan ⑦，隐私底线清单，可在 UI 增删）：名单内的包
  /// 无论是否加进采集白名单都不采（黑名单优先于白名单，由 Kotlin 侧
  /// isBlocked() 保证）。默认内置支付宝与云闪付的包名，外加 Soul——它是旧
  /// CaptureService BLOCKED_PKGS 的原有成员（防截屏应用，永不读取），随黑名单
  /// 可配置化并入这份清单，避免首次 configure 把它冲掉。
  ///
  /// 银行类 App 的「com.android.bank 前缀命中即拦」是同一条底线的另一半：
  /// 前缀规则不持久化、不进这份可编辑集合，硬编码在 Kotlin isBlocked() 里
  /// （底线不可被 UI 清空）。
  final ValueNotifier<Set<String>> blockedPackages =
      ValueNotifier(Set<String>.of(defaultBlockedPackages));

  /// 黑名单默认值（Kotlin CaptureService 的默认集合与此镜像；Dart 侧是
  /// 可编辑清单的单一事实来源，Kotlin 默认值只在 configure 到来之前兜底）。
  static const Set<String> defaultBlockedPackages = {
    'com.eg.android.AlipayGmobile', // 支付宝
    'com.unionpay', // 云闪付
    'cn.soulapp.android', // Soul（防截屏应用，旧采集服务基线）
  };

  /// 候选展示模式（p0-plan B8）：[displayModePrimary] = 主推排序第一张大卡、
  /// 备选折叠；[displayModeAll] = 全部候选平铺。消费方读 [displayMode]，
  /// 写入方负责二选一；load 对存档里的其它值一律落回默认。
  final ValueNotifier<String> displayMode =
      ValueNotifier(displayModePrimary);

  /// 候选展示模式取值：主推一张大卡（默认）。
  static const String displayModePrimary = 'primary';

  /// 候选展示模式取值：全部展开。
  static const String displayModeAll = 'all';

  /// 首次运行引导完成标记（p0-plan ②）：默认 false，引导页走完写 true；
  /// 主入口据此决定先进引导页还是进首页。
  final ValueNotifier<bool> onboarded = ValueNotifier(false);

  /// 引导第一步「选场景」记住的场景 id（p0-plan ②「单选并记住」），取值是
  /// Scenarios.builtIns 的稳定键。空串 = 未引导/未选；消费方用 Scenarios.byId
  /// 查不到时退回默认场景（chat_copilot）。本阶段只有引导页写它，采集与
  /// 起草流水线消费场景附加段的接线在后续工作流。
  final ValueNotifier<String> scenarioId = ValueNotifier('');

  // ------------------------------------------------------------------ 存取

  /// 应用启动时调用：读存档，逐项灌入上面的 ValueNotifier。
  ///
  /// 首次启动没有存档、整包 JSON 损坏、或平台通道不可用（如测试环境）
  /// 一律保持默认值并原样返回——坏存档不该挡住启动。存档内 config 缺键
  /// 由 [JevConfig.fromJson] 落回字段默认值；replyKey/judgeKey 从安全区读回
  /// （见下），存档里本就不该有它们的明文。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      Map<String, dynamic>? decoded;
      if (raw != null && raw.isNotEmpty) {
        try {
          final Object? parsed = jsonDecode(raw);
          if (parsed is Map<String, dynamic>) decoded = parsed;
        } on FormatException {
          // 整包 JSON 损坏：按没存过处理，用默认值。
        }
      }
      if (decoded != null) {
        final savedConfig = decoded['config'];
        if (savedConfig is Map<String, dynamic>) {
          // F2 首版迁移：旧存档把 key 明文放在 config 里，读到即搬入安全区
          // 并从存档删除原值（详见 [_migratePlainKeys]）。
          await _migratePlainKeys(prefs, decoded, savedConfig);
          // 明文迁移后 savedConfig 已无 key 字段；合并安全区里的 key。
          final merged = Map<String, dynamic>.from(savedConfig);
          final replyKey = await _readSecure(_secureReplyKey);
          if (replyKey != null && replyKey.isNotEmpty) {
            merged['replyKey'] = replyKey;
          }
          final judgeKey = await _readSecure(_secureJudgeKey);
          if (judgeKey != null && judgeKey.isNotEmpty) {
            merged['judgeKey'] = judgeKey;
          }
          config.value = JevConfig.fromJson(merged);
        }
        final savedRelationship = decoded['relationship'];
        if (savedRelationship is String) relationship.value = savedRelationship;
        final savedOverlay = decoded['overlayEnabled'];
        if (savedOverlay is bool) overlayEnabled.value = savedOverlay;
        final savedBlocked = decoded['blockedPackages'];
        if (savedBlocked is List) {
          blockedPackages.value = savedBlocked.whereType<String>().toSet();
        }
        final savedDisplayMode = decoded['displayMode'];
        if (savedDisplayMode == displayModePrimary ||
            savedDisplayMode == displayModeAll) {
          displayMode.value = savedDisplayMode as String;
        }
        final savedOnboarded = decoded['onboarded'];
        if (savedOnboarded is bool) onboarded.value = savedOnboarded;
        final savedScenarioId = decoded['scenarioId'];
        if (savedScenarioId is String) scenarioId.value = savedScenarioId;
      }
    } catch (_) {
      // shared_preferences / 安全区不可用（平台通道缺失等）：保持内存默认值。
    }
  }

  /// F2 首版迁移：旧版本把 replyKey/judgeKey 明文整包存进 shared_preferences。
  /// 存档 config 里读到非空明文 key 就写进安全区，然后把这两个键从存档删掉、
  /// 立即重写整包（删除原值）。迁移是幂等的：迁移过的存档没有这两个键，直接
  /// 跳过；安全区写失败则原样保留明文（宁可维持旧的明文行为也不弄丢用户的
  /// key），下次启动再迁。
  Future<void> _migratePlainKeys(
    SharedPreferences prefs,
    Map<String, dynamic> decoded,
    Map<String, dynamic> savedConfig,
  ) async {
    final replyKey = savedConfig['replyKey'];
    final judgeKey = savedConfig['judgeKey'];
    final hasPlain = (replyKey is String && replyKey.isNotEmpty) ||
        (judgeKey is String && judgeKey.isNotEmpty);
    if (!hasPlain) return;
    var allWritten = true;
    if (replyKey is String && replyKey.isNotEmpty) {
      try {
        await _secure.write(key: _secureReplyKey, value: replyKey);
      } catch (_) {
        allWritten = false;
      }
    }
    if (judgeKey is String && judgeKey.isNotEmpty) {
      try {
        await _secure.write(key: _secureJudgeKey, value: judgeKey);
      } catch (_) {
        allWritten = false;
      }
    }
    if (!allWritten) return;
    // 从内存 map 与磁盘存档里同时删除明文。这里不走 [save]：save 写的是内存
    // notifier 的当前值，而此刻内存还没灌入存档值，会把未加载的默认值覆盖上盘。
    savedConfig.remove('replyKey');
    savedConfig.remove('judgeKey');
    try {
      await prefs.setString(_storageKey, jsonEncode(decoded));
    } catch (_) {
      // 重写失败：明文仍在盘上但已进安全区，下次启动会再清理一次。
    }
  }

  /// 设置页保存时调用：key 先写安全区，其余字段整包写盘。顺序有讲究——先
  /// 安全区后 prefs：若第二步失败，安全区已持有新 key，下次启动读到的是新值；
  /// 反过来则可能把旧 key 留在安全区，静默复活盖掉用户刚改的 key。
  Future<void> save() async {
    final c = config.value;
    await _writeSecure(_secureReplyKey, c.replyKey);
    await _writeSecure(_secureJudgeKey, c.judgeKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(toJson()));
  }

  /// 存档形状：config（不含 replyKey/judgeKey 明文——它们只存安全区，见
  /// [_secureReplyKey]）+ relationship + 悬浮窗开关 + 黑名单 + 展示模式 +
  /// 引导标记。键名固定，load 与 save 共用同一份形状，字段增减两处一起改。
  Map<String, dynamic> toJson() {
    final configJson = config.value.toJson()
      ..remove('replyKey')
      ..remove('judgeKey');
    return <String, dynamic>{
      'config': configJson,
      'relationship': relationship.value,
      'overlayEnabled': overlayEnabled.value,
      'blockedPackages': blockedPackages.value.toList(),
      'displayMode': displayMode.value,
      'onboarded': onboarded.value,
      'scenarioId': scenarioId.value,
    };
  }

  void dispose() {
    config.dispose();
    relationship.dispose();
    overlayEnabled.dispose();
    blockedPackages.dispose();
    displayMode.dispose();
    onboarded.dispose();
    scenarioId.dispose();
  }
}
