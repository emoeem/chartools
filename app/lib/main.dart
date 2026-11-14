// ---------------------------------------------------------------------------
// #13 资料三页接线登记（本次唯一改动文件：app/lib/main.dart）
//
// 涉及文件与决策：
// - 消费但不改动：application/knowledge_controller.dart、
//   application/experts_controller.dart、application/personas_controller.dart
//   （构造签名按各自类文档）、ui/knowledge_page.dart、ui/experts_page.dart、
//   ui/personas_page.dart、core 的 KbStore（kb_store.dart）。
// - 入口（任务 1）：设置页顶部新增「资料」入口组——知识库 / 专家团 / 人设库
//   三个 ListTile（副标题一句话说明），push 时经 [_PageHost] 接入对应页面。
//   首页不加快捷入口（任务 4 的判断，理由见 ScenarioListPage 文档），不重排
//   首页；原 main.dart:229 起的 CapturePage(scenarioId: store.scenarioId)
//   高危链路（fix(#11 P0-N) 注释段）一字未动。
// - 本轮（外部审阅三项接线，均在此文件落地）：① 人设库入口补注入
//   SettingsStyleSink / ContactStorePersonaSink（套用落点，语义见
//   personas_controller.dart 套用一节）；② 知识库路由 AppBar 补「导入」动作
//   （showKnowledgeImportSheet，页面本体 body-only 分工不变）；③ 首页场景
//   卡片从静态展示升级为选择面（点卡片写 store.scenarioId + 落盘）——
//   ScenarioListPage 文档记录了对旧裁决「首页不加快捷入口」的**部分推翻**
//   （导航快捷入口仍不加，推翻的只是「场景卡保持静态」那半条）。
//   CapturePage(scenarioId:) 链路一字未动：卡片写的就是采集流消费的同一
//   notifier（fix(#11 P0-N) 的同源值）。
// - 控制器生命周期：「页面所有者构造与 dispose」——push 时构造、路由退场
//   dispose，落点是 [_PageHost]。**实测三个页面自身不构造也不 dispose 注入
//   的控制器**（knowledge_page.dart:66-70 只摘监听 + 释放搜索框、
//   experts_page.dart:34-37 释放搜索框、personas_page.dart 无页面级
//   dispose）——「页面 dispose 自理」在代码里的真实形状是「页面只管自己的
//   内部输入框」，控制器收尾因此归页面所有者（[_PageHost]）；main 不代持
//   （无应用级控制器持有者，pop 即回收，下次 push 重新构造、重新 load）。
// - KbStore 实例（任务 2）：应用级一份，生产在 main() 读档（Android/Linux
//   走 path_provider 支持目录 + 一次性旧档迁移）后经 ChartoolsApp 构造注入，
//   随根 State 存活；消费点=知识库页/迁移页 + **采集页与桌面流页（独立复核
//   补接线）**——CapturePage 透传给 CaptureSession.knowledgeBase，桌面流
//   _buildCtx 走 CaptureSession.knowledgeRefsOf 现查，热键路由同一实例。
//   直接 pump 的测试不传 kbStore，根 State initState 用同步降级自举。
// - 坏档兜底（任务 3，#12 复核必做项）：[_bootKnowledgeStore] 显式 catch
//   KbStore.loadFromFileSync 的 FormatException——坏档改名挪为
//   `<存档>.corrupt.<毫秒>` 备份（KbStore 自己不删数据，挪档在 app 层做；
//   时间戳后缀沿用 legacy KbStore.kt:539 的保全思路，不覆盖旧备份）后空档
//   续跑，首帧经 root messenger 弹「存档已损坏：已将原档挪为 .corrupt 备份
//   并新建空档」。挪档失败退化为纯内存档（绝不挂着路径覆盖坏档），提示
//   如实改说。存档路径见 [_kbArchivePath]：SettingsStore 走 shared_preferences
//   无现成文件路径可借，按平台推导；Android 的 cache 妥协点已标注。
// - migration 页接线（fixer 阶段补上，登记待办在此销账）：MigrationPage 挂
//   设置页「资料」组第四个入口，MigrationController 包住应用级 KbStore（迁移
//   目标库与知识库页同一份——迁进来的笔记/联系人当场在知识库页可见）；控制
//   器生命周期同落 [_PageHost]（MigrationController.dispose 收三个
//   ValueNotifier）。ZIP/SAF 文件选择器仍按 migration_page.dart 头注释留给
//   后续（v1 收三段文本粘贴）。
// - fixer 其他补笔（第 1 轮门禁后的编译修复）：根 State 的启动读档从
//   createState 挪进 initState（createState 只构造 State 本身），_KbBoot
//   的拆包装配随之入 initState——字段语义与首帧时序不变。
// ---------------------------------------------------------------------------
import 'dart:convert';
// #13 接线引入 dart:io：应用级 KbStore 的启动读档与坏档挪移是文件操作。
// core 零第三方依赖的纪律不变；app 层本就有平台面（hotkey 的 win32 FFI），
// web 不在本应用支持矩阵内（采集/热键/粘贴分析三入口均已按平台分支）。
import 'dart:io' show Directory, File, Platform;
// AppExitResponse 只在 dart:ui（platform_dispatcher.dart 的枚举），material/
// widgets 都不转发这个符号（widgets/binding.dart 自己也是从 dart:ui show 进
// 来的），覆写 didRequestAppExit 必须显式带这一行。
import 'dart:ui' show AppExitResponse;

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// 独立复核补接线（知识注入 + Android 存档持久化）：应用级 KbStore 的存档
// 目录在 Android/Linux 走 path_provider 的应用支持目录（进程 cache 目录可能
// 被系统清理，存档是唯一真源，不能落那里）。已在 app/pubspec.yaml 声明直依
// （锁内 2.1.6，path_provider_android 钉 2.2.23 无 jni/CMake 问题）。
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'application/contact_store.dart';
// #13 资料三页接线：控制器与页面按构造签名消费（不改动它们的文件）。
// 注意 experts_controller.dart 与 core 各有一套 ExpertPack/ExpertCatalog
// 命名（core 是严格校验的 PackCodec 路径，app 是宽容解析路径），本文件只
// 引用控制器/适配器三个名字，不触碰那批重名类，避开二义引用。
import 'application/experts_controller.dart';
import 'application/hotkey_controller.dart';
import 'application/knowledge_controller.dart';
import 'application/model_presets.dart';
// fixer 补接线（migration 页）：控制器与页面按各自构造签名消费
// （migration_controller.dart:28 / migration_page.dart:36）。
import 'application/migration_controller.dart';
import 'application/personas_controller.dart';
import 'application/settings_store.dart';
import 'ui/capture_page.dart';
import 'ui/desktop_assistant_page.dart';
import 'ui/experts_page.dart';
import 'ui/knowledge_page.dart';
import 'ui/migration_page.dart';
import 'ui/onboarding_page.dart';
import 'ui/personas_page.dart';
import 'ui/settings_page.dart';

/// G7 偏好档案的存档键（shared_preferences）。C 的 PreferenceProfile 只给
/// toJson/fromJson（core 不落盘，见 preference_profile.dart 类注释），读写
/// 时机由 app 层接线——这里就是接线处：启动读盘，record/clear 之后写盘。
const String _preferenceProfileKey = 'preference_profile';

/// 启动时读偏好档案：坏档/无档降级为空档案，不打断启动（C 的 fromJson 本身
/// 容错，这里再兜一层平台通道异常）。
Future<PreferenceProfile> _loadPreferences() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_preferenceProfileKey);
    if (raw == null || raw.isEmpty) return PreferenceProfile();
    final Object? decoded = jsonDecode(raw);
    return PreferenceProfile.fromJson(
        decoded is Map<String, dynamic> ? decoded : null);
  } catch (e) {
    // fix(#8 DS-6) 读档失败不再全吞：debugPrint 留痕（磁盘满、平台通道异常
    // 这类环境问题有迹可循）。降级行为不变——按空档案继续，不打断启动。
    debugPrint('偏好档案读盘失败，按空档案继续：$e');
    return PreferenceProfile();
  }
}

/// record/clear 之后写盘：失败不再全吞（fix(#8 DS-6)）——debugPrint 留痕后
/// 照旧继续，内存里的偏好仍然生效，不打扰用户的口径不变。设置页自己的保存
/// 路径已有「已生效但写盘失败」的 SnackBar（[SettingsPage._save]），那条
/// 路径保持不动。
Future<void> _savePreferences(PreferenceProfile preferences) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _preferenceProfileKey, jsonEncode(preferences.toJson()));
  } catch (e) {
    // fix(#8 DS-6) 写盘失败至少 debugPrint 留痕，不再无声丢失。
    debugPrint('偏好档案写盘失败：$e');
  }
}

/// fix(#8 DS-8) 退出清理观察者：Windows 关窗会先走框架的退出请求流程——
/// runner 的 FlutterWindow::MessageHandler 把窗口消息先转给引擎
/// （flutter_window.cpp 的 HandleTopLevelWindowProc），embedder 把 WM_CLOSE
/// 转成 requestAppExit，最后由 [WidgetsBindingObserver.didRequestAppExit]
/// 逐个询问观察者（任一返回 cancel 才取消，否则放行，见 widgets
/// binding.dart 的 handleRequestAppExit）。这里抢在放行前反注册全局热键并
/// 关停泵线程；非 Windows 下 [HotkeyController.stop] 是空操作，观察者常驻
/// 无害。兜底：即便反注册的异步收尾没赶上进程退出，OS 在进程终止时也会
/// 回收本进程注册的所有热键。
class _HotkeyExitObserver with WidgetsBindingObserver {
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await HotkeyController.instance.stop();
    // 只做清理，不拦退出：返回 exit 放行。
    return AppExitResponse.exit;
  }
}

// ---------------------------------------------------------------------------
// 应用级 KbStore 的启动接线（#13，任务 2/3）
// ---------------------------------------------------------------------------

/// 坏档提示的投递口：读档发生在根 State initState（那时没有 context 可弹
/// UI），首帧之后经 root messenger 投递（挂接在 MaterialApp 的
/// scaffoldMessengerKey 上）。挂全局而不是埋进某个页面：坏档提示属于
/// 「启动事件」，无论首屏是引导页还是场景首页都该看到。
final GlobalKey<ScaffoldMessengerState> _kbNoticeMessengerKey =
    GlobalKey<ScaffoldMessengerState>(debugLabel: 'kbCorruptNotice');

/// 应用级 KbStore 的存档路径（#13 接线决策 + 独立复核补正）。
///
/// SettingsStore 走 shared_preferences，没有现成文件路径可借；kb_store.dart
/// 文档只约定「单一存档文档」的形状，文件名沿用知识页接线示例的 kb.json
/// （knowledge_page.dart:11 的 `<数据目录>/kb.json`）。目录按平台：
/// - **Windows（生产）**：`%APPDATA%/chartools` —— 与既有存档位置一致，
///   刻意**不**切 path_provider（它的支持目录带 `<公司>/<产品>` 两段，会把
///   老档孤儿化），应用自有数据聚在一处，排查时不用两处找；
/// - **Android（生产）**：path_provider 的应用支持目录（= filesDir，应用
///   私有、持久、不随存储压力被清）——修复「cache 目录可能被系统清」的
///   数据丢失风险，见 [_migrateLegacyKbArchive] 的一次性旧档迁移；
/// - **Linux 桌面（生产）**：同走 path_provider 支持目录（原 TEMP 落点的
///   同款风险，一并修掉）；
/// - **降级/测试**（平台通道不可用，如 widget 测试直 pump 根组件）：退回
///   [_kbArchivePathFallback] 的手推路径（TEMP/TMP/系统临时目录）。
///
/// 斜杠统一用 `/`：dart:io 的 File 在 Windows 下两种分隔符都认，不必手拼。
Future<String> _kbArchivePath() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return _kbArchivePathFallback();
  }
  try {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/chartools/kb.json';
  } catch (_) {
    // 平台通道不可用（测试 / 插件缺失 / 降级运行）：退回手推路径。
    return _kbArchivePathFallback();
  }
}

/// 手推的存档路径（path_provider 出现之前的既有实现，现作降级/测试路径；
/// 也是 Android/Linux 旧档的**迁移源位置**）：
/// - Windows：`%APPDATA%/chartools`；
/// - Android：进程私有 `TMPDIR`（init 设到本应用 cache 目录）；
/// - 其余：TEMP/TMP 或系统临时目录。
String _kbArchivePathFallback() {
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    return '$appData/chartools/kb.json';
  }
  final tmp = Platform.environment['TMPDIR'] ??
      Platform.environment['TEMP'] ??
      Platform.environment['TMP'];
  final base =
      (tmp != null && tmp.isNotEmpty) ? tmp : Directory.systemTemp.path;
  return '$base/chartools/kb.json';
}

/// 一次性旧档迁移（独立复核补接线）：Android/Linux 的存档曾落 cache/TEMP
/// 目录（系统可清 = 数据可丢），现改落应用支持目录。新位置没有档而老位置
/// 有 → 把老档**复制**过来（不删老档：它在 cache 里本就是系统可清的副本，
/// 留着当备份零成本）。复制失败不炸启动：按「新位置无档」继续空档起步，
/// 老档原地保留待重试。Windows 新老路径相同，天然空操作。
Future<void> _migrateLegacyKbArchive(String newPath) async {
  final newFile = File(newPath);
  if (newFile.existsSync()) return;
  final oldPath = _kbArchivePathFallback();
  if (oldPath == newPath) return;
  final oldFile = File(oldPath);
  if (!oldFile.existsSync()) return;
  try {
    await newFile.parent.create(recursive: true);
    await oldFile.copy(newPath);
    debugPrint('知识库存档已从 $oldPath 迁移到 $newPath');
  } catch (e) {
    debugPrint('知识库存档迁移失败（$e）：按新位置空档起步，旧档原地保留');
  }
}

/// [_bootKnowledgeStore] 的结果：存档实例 + 首帧提示（null = 存档正常，
/// 绝大多数启动走这条）。
class _KbBoot {
  const _KbBoot(this.store, this.notice);

  final KbStore store;

  /// null = 正常；非空 = 首帧后要弹的 SnackBar 文案。
  final String? notice;
}

/// 应用级 KbStore 的启动读档（#12 复核指出的 main 接线必做项）。生产路径
/// （[main]）用异步版：解析存档路径（Android/Linux 走 path_provider，见
/// [_kbArchivePath]）→ 一次性旧档迁移（[_migrateLegacyKbArchive]）→ 读档。
///
/// KbStore 的契约（kb_store.dart:656-658）：文件损坏抛 FormatException 交给
/// 调用方处置——「挪开再重写」是 app 层的活，core 不替用户把读不回来的数据
/// 当垃圾扔。这里的处置顺序：
///
/// 1. 正常读档；
/// 2. FormatException（坏档）→ 把坏档**改名挪开**为 `<存档>.corrupt.<毫秒>`
///    （沿用 legacy KbStore.kt:539 的时间戳后缀：绝不覆盖既有备份——坏档也
///    是用户数据，保全到人工排查为止），然后重新 loadFromFileSync 拿到空档
///    （archivePath 已挂上，后续变更照常落盘），提示用既定文案；
/// 3. 挪档失败（Windows 文件占用等）→ 退化为**纯内存档**（archivePath 为空
///    即纯内存，见 kb_store.dart:21）：绝不挂着路径继续跑——否则首次 flush
///    会把还没挪走的坏档覆盖掉，那才是二次破坏。提示如实改说，不冒领
///    「已挪为备份」。
///
/// 只显式 catch FormatException（存档内容损坏，可救）；磁盘级
/// FileSystemException 属环境故障，原样上抛让启动失败，不做静默兜底。
Future<_KbBoot> _bootKnowledgeStore() async {
  final path = await _kbArchivePath();
  await _migrateLegacyKbArchive(path);
  return _bootKnowledgeStoreAt(path);
}

/// 生产/测试共用的读档核心（坏档兜底三步），按给定路径同步执行。
_KbBoot _bootKnowledgeStoreAt(String path) {
  try {
    return _KbBoot(KbStore.loadFromFileSync(path), null);
  } on FormatException catch (e) {
    debugPrint('知识库存档损坏（$e）：挪为 .corrupt 备份后空档续跑');
    final backup =
        File('$path.corrupt.${DateTime.now().millisecondsSinceEpoch}');
    try {
      File(path).renameSync(backup.path);
    } catch (renameError) {
      // 挪不开就不挂路径：纯内存续跑，坏档原地保留（宁可不落盘，不覆盖）。
      debugPrint('坏档挪移失败（$renameError）：本次知识库以纯内存运行');
      return _KbBoot(
        KbStore(),
        '存档已损坏且未能挪为备份：本次知识库以纯内存运行，原档保留待排查',
      );
    }
    return _KbBoot(
      KbStore.loadFromFileSync(path),
      '存档已损坏：已将原档挪为 .corrupt 备份并新建空档',
    );
  }
}

/// 同步降级自举（仅根 State initState 兜底用）：直接 pump [ChartoolsApp]
/// 的 widget 测试不传 kbStore 时，initState 里没有 async 可等，退回手推
/// 路径同步读档——读不到就是空档，行为与接线前一致。生产永远走
/// [_bootKnowledgeStore]（main 里注入），不经过这里。
_KbBoot _bootKnowledgeStoreSync() =>
    _bootKnowledgeStoreAt(_kbArchivePathFallback());

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // fix(#8 DS-8) 接线退出清理：热键反注册挂在退出请求钩子上（Windows 关窗
  // 即触发）。观察者随进程存活，无须移除。
  WidgetsBinding.instance.addObserver(_HotkeyExitObserver());
  // 启动即读存档：拿到持久化的设置再进 UI，避免先渲染默认值再跳变。
  // 读不到存档（首次启动 / JSON 损坏 / 平台通道不可用）就按默认值起。
  final store = SettingsStore();
  await store.load();
  // #6 联系人档案与 G7 偏好：同样在进 UI 前读盘。ContactStore 的持久化在
  // A 的 contact_store.dart（load 与 SettingsStore.load 同一节奏；签名以
  // A notes 为准）。两份都经构造参数注入采集页与桌面流页。
  final contactStore = ContactStore();
  await contactStore.load();
  final preferences = await _loadPreferences();
  // 应用级 KbStore（#13 任务 2/3 + 独立复核补接线）：启动即读档（Android/
  // Linux 走 path_provider 支持目录 + 一次性旧档迁移），生产全部消费点——
  // 知识库页/迁移页/采集流/桌面流（含热键路由）——共用这一份实例。
  final kbBoot = await _bootKnowledgeStore();
  // Windows 全局热键（Ctrl+Alt+C）启动即恢复：存档开关默认开，热键把桌面
  // 助手页切到前台（路由工厂在这里建——只有 main 持有 store/contactStore 等
  // 页面参数）。非 Windows 是空操作。控制器细节见 hotkey_controller.dart。
  if (HotkeyController.isSupported) {
    await HotkeyController.instance.startup(
      routeFactory: () => MaterialPageRoute<void>(
        settings:
            const RouteSettings(name: HotkeyController.assistantRouteName),
        builder: (_) => DesktopAssistantPage(
          config: store.config,
          displayMode: store.displayMode,
          // fix(#11 P0-N) 场景接线：引导页「选场景」写的那份 notifier，桌面流
          // 与采集流共用同一份值、同一个解析点（CaptureSession.resolveScenario）。
          scenarioId: store.scenarioId,
          contactStore: contactStore,
          preferences: preferences,
          // 知识检索注入（独立复核补接线）：热键路由的桌面流与首页入口共用
          // 同一份应用级 KbStore（main 在 runApp 前读好档，路由工厂闭包捕获）。
          knowledgeBase: kbBoot.store,
          // C9 接线：统计与设置页/采集流是同一份实例（usage_stats.dart 契约）。
          usage: store.usage,
          // 与下方 runApp 传的同款闭包（main() 里它不是具名变量，这里就地重建）。
          persistPreferences: () {
            _savePreferences(preferences);
          },
        ),
      ),
    );
  }
  // 未完成首次运行引导（p0-plan ②）就先落三步引导页；引导页点「完成」后
  // 自己换到场景首页。直接 pump ChartoolsApp 的测试不走这里（默认进场景首页）。
  runApp(ChartoolsApp(
    store: store,
    contactStore: contactStore,
    preferences: preferences,
    persistPreferences: () {
      _savePreferences(preferences);
    },
    startOnOnboarding: !store.onboarded.value,
    // 应用级 KbStore（含坏档首帧提示）：main 读好档经构造注入，根 State 不再
    // 自举（直接 pump 的测试不传，走 initState 同步降级，见 ChartoolsApp 文档）。
    kbStore: kbBoot.store,
    kbNotice: kbBoot.notice,
  ));
}

/// 应用根：内存里持有一份设置（[SettingsStore] 的 ValueNotifier），设置页
/// 改它、连通性测试读它。启动时从 shared_preferences 加载，设置页的保存
/// 按钮写盘（见 application/settings_store.dart）。
///
/// #13 接线：本组件由 StatelessWidget 改为 StatefulWidget——应用级 [KbStore]
/// 生产由 [main] 读档后经 [kbStore] 注入（独立复核补接线：这份实例同时供给
/// 采集流/桌面流），随根 State 存活；直接 pump 本组件的既有测试不传
/// [kbStore]，根 State initState 走同步降级自举（[_bootKnowledgeStoreSync]，
/// 存档不存在时 boot 只做一次 existsSync，零写入）。
class ChartoolsApp extends StatefulWidget {
  const ChartoolsApp({
    super.key,
    required this.store,
    this.contactStore,
    this.preferences,
    this.persistPreferences,
    this.startOnOnboarding = false,
    this.kbStore,
    this.kbNotice,
  });

  final SettingsStore store;

  /// #6 联系人档案（A 的 ContactStore）：可选——直接 pump 本组件的测试不传，
  /// 两页的联系人区不渲染（生产路径由 main() 注入）。
  final ContactStore? contactStore;

  /// G7 结构化偏好（C 的 PreferenceProfile）：可选，同上。
  final PreferenceProfile? preferences;

  /// G7 偏好落盘回调（main() 注入）：两页 record/clear 之后触发。
  final void Function()? persistPreferences;

  /// true：首页先落三步引导（[OnboardingPage]）。默认 false——引导门控只由
  /// 主入口在 [SettingsStore.load] 之后决定，直接 pump 本组件的测试与工具页
  /// 不受它影响。
  final bool startOnOnboarding;

  /// #13 应用级知识库存档（可选——main() 注入生产实例；直接 pump 的测试不
  /// 传，根 State initState 用 [_bootKnowledgeStoreSync] 自举）。与知识库页/
  /// 迁移页/采集流/桌面流共用同一份。
  final KbStore? kbStore;

  /// 启动读档遇坏档时的首帧提示文案（[kbStore] 一并注入时才可能有值）；
  /// null = 存档正常。
  final String? kbNotice;

  @override
  State<ChartoolsApp> createState() => _ChartoolsAppState();
}

class _ChartoolsAppState extends State<ChartoolsApp> {
  /// 应用级知识库存档（#13 任务 2 的落点）：生产由 main() 读档后经
  /// [ChartoolsApp.kbStore] 注入，**采集流/桌面流也共用这一份**（独立复核
  /// 补接线——CapturePage/DesktopAssistantPage 的构造参数与热键路由同一
  /// 实例）；知识库入口 push 时包进 KnowledgeController 做增删改查与落盘。
  /// 直接 pump 的测试不传 widget.kbStore：initState 用 [_bootKnowledgeStoreSync]
  /// 同步自举（无平台通道，手推路径，读不到即空档）。
  late final KbStore kbStore;

  /// 启动读档遇到坏档时的首帧提示文案；null = 存档正常。
  late final String? kbNotice;

  @override
  void initState() {
    super.initState();
    // 生产：main 读好档经构造注入（initState 只接手，不再做文件 IO）。
    // 测试/降级：widget.kbStore 为 null → 同步自举（initState 无 async 可等，
    // 手推路径 + 坏档兜底与生产同一套 [_bootKnowledgeStoreAt] 核心）。
    final provided = widget.kbStore;
    if (provided != null) {
      kbStore = provided;
      kbNotice = widget.kbNotice;
    } else {
      final boot = _bootKnowledgeStoreSync();
      kbStore = boot.store;
      kbNotice = boot.notice;
    }
    final notice = kbNotice;
    if (notice == null) return;
    // 读档在 main/initState 完成（都无 context 可弹 UI）：挪到首帧之后经
    // root messenger 投递，坏档提示在首屏 Scaffold 就绪后立即出现；mounted
    // 守卫防极端时序。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _kbNoticeMessengerKey.currentState
          ?.showSnackBar(SnackBar(content: Text(notice)));
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chatools · 通用沟通助手',
      // 热键导航（Windows 全局热键唤起桌面助手页）：控制器需要从 app 外把
      // 页面推入栈顶，拿不到 BuildContext，只能经 navigatorKey（见
      // hotkey_controller.dart 的 _handleActivated）。非 Windows 下它闲置。
      navigatorKey: HotkeyController.instance.navigatorKey,
      // #13 坏档提示的投递口（见 _kbNoticeMessengerKey 文档）。
      scaffoldMessengerKey: _kbNoticeMessengerKey,
      // fix(#11 P0-3)：采集页 RouteAware 的路由观察者接线——RouteAware 的
      // didPopNext（应用内路由 pop 回来触发采集页刷新）依赖观察者被
      // navigatorObservers 引用才会派发；实例由 CapturePage 静态持有（进程
      // 一份，main.dart 已 import capture_page.dart）。
      navigatorObservers: [CapturePage.routeObserver],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: widget.startOnOnboarding
          ? OnboardingPage(
              store: widget.store,
              homeBuilder: (_) => ScenarioListPage(
                store: widget.store,
                kbStore: kbStore,
                contactStore: widget.contactStore,
                preferences: widget.preferences,
                persistPreferences: widget.persistPreferences,
              ),
            )
          : ScenarioListPage(
              store: widget.store,
              kbStore: kbStore,
              contactStore: widget.contactStore,
              preferences: widget.preferences,
              persistPreferences: widget.persistPreferences,
            ),
    );
  }
}

/// 首页：内置五场景（[Scenarios.builtIns]）+ 右上角进设置。
///
/// #13 任务 4 的旧裁决（「首页不加快捷入口」）**部分推翻，原因记录在此**：
/// 当时的对象是「资料/知识库一类管理面的导航快捷入口」——那条仍然成立，
/// 「资料」入口组留在设置页顶部，本轮没有给首页加任何导航入口。推翻的是
/// 它的另一半：场景卡片此前是纯静态展示（外部审阅 ③ 取证），而场景已经
/// 接进起草链路（fix(#11 P0-N)），用户引导完之后却改不了场景——引导入口
/// 只在首启出现，等于「选一次用一辈子」。所以本轮把首页场景卡片升级成
/// **选择面**：当前选中 = [SettingsStore.scenarioId] 持久化值，点卡片写入
/// store（视觉反馈 + 落盘），不新增导航、不重排页面。「不选场景」的路径
/// 保持：没选过就明确显示「未指定（按默认聊天副驾执行）」，不强制选。
class ScenarioListPage extends StatelessWidget {
  const ScenarioListPage({
    super.key,
    required this.store,
    required this.kbStore,
    this.contactStore,
    this.preferences,
    this.persistPreferences,
  });

  final SettingsStore store;

  /// #13 应用级知识库存档（main 注入，随根 State 存活）：透传给设置页的
  /// 「资料」入口组，**并传给采集页/桌面流页做知识检索注入**（独立复核补
  /// 接线——生产注入此前落空，四个组 ctx 调用点恒拿空表）。本页自己不消费。
  final KbStore kbStore;

  /// #6 联系人档案与 G7 偏好：透传给两个助手入口页（构造参数注入）。
  final ContactStore? contactStore;
  final PreferenceProfile? preferences;
  final void Function()? persistPreferences;

  /// 点场景卡：写 [SettingsStore.scenarioId]（采集/桌面流每轮从同一 notifier
  /// 现读，下一批候选即生效——与引导页 onboarding_page.dart:213 的写入同一
  /// 语义）并尽力落盘。写盘失败不阻塞切换：内存 notifier 已生效，落盘失败
  /// 的代价只是重启后回落上一次成功落盘的值；吞异常是因为 flutter_secure_
  /// storage 等通道问题不该把「换场景」变成报错现场。
  Future<void> _switchScenario(String id) async {
    store.scenarioId.value = id;
    try {
      await store.save();
    } catch (_) {
      // 落盘失败不阻塞：见上。
    }
  }

  @override
  Widget build(BuildContext context) {
    final scenarios = Scenarios.builtIns;
    return Scaffold(
      appBar: AppBar(
        title: const Text('通用沟通助手'),
        actions: [
          // 采集助手只在 Android 出现：读屏与回填是 Android 独占能力。桌面
          // （Windows）没有采集层，入口换成「粘贴分析」——两个入口互斥
          // （if / else if），同一时刻只出现一个。
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            IconButton(
              icon: const Icon(Icons.assistant),
              tooltip: '采集助手',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CapturePage(
                    config: store.config,
                    relationship: store.relationship,
                    overlayEnabled: store.overlayEnabled,
                    // B8 候选展示模式：与设置页共享同一份 notifier（此前漏接，
                    // 展示模式被永久钉在 primary）。悬浮窗同构模式由
                    // CaptureSession 从同一份 notifier 在推候选时透传。
                    displayMode: store.displayMode,
                    // fix(#11 P0-N) 场景接线（独立复核补接）：采集流此前漏接
                    // scenarioId——引导页选的场景只对桌面流生效，Android 采集
                    // 流每轮 resolveScenario 都拿到 null。现在与热键路由/粘贴
                    // 分析入口同源（store.scenarioId），同一份值、同一个解析点。
                    scenarioId: store.scenarioId,
                    // 采集应用黑名单（p0-plan ⑦）：与设置页同一份清单。
                    blockedPackages: store.blockedPackages,
                    // #6 联系人档案与 G7 结构化偏好（可查可改可删）+ 落盘回调。
                    contactStore: contactStore,
                    preferences: preferences,
                    persistPreferences: persistPreferences,
                    // C9/C10 接线：统计打点与检查点存取都是 SettingsStore 的
                    // 同一份（usage_stats.dart 契约；检查点恢复必须过确认）。
                    usage: store.usage,
                    writeCheckpoint: store.saveSessionCheckpoint,
                    sessionCheckpoint: store.sessionCheckpoint,
                    // 知识检索注入（独立复核补接线）：应用级 KbStore 与知识
                    // 库页同一份，随 CaptureSession 进四个组的 ctx 调用点。
                    knowledgeBase: kbStore,
                  ),
                ),
              ),
            )
          else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
            IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: '粘贴分析',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  // 热键 popUntil 以路由名识别「页面已在栈上」；手动入口推的
                  // 路由也带上同一个名字（见 HotkeyController.assistantRouteName）。
                  settings: const RouteSettings(
                      name: HotkeyController.assistantRouteName),
                  builder: (_) => DesktopAssistantPage(
                    config: store.config,
                    // B8 候选展示模式：与设置页共享同一份 notifier（此前漏接）。
                    displayMode: store.displayMode,
                    // fix(#11 P0-N) 场景接线：与热键路由那份同源（store.scenarioId）。
                    scenarioId: store.scenarioId,
                    // #6 联系人档案与 G7 结构化偏好（可查可改可删）+ 落盘回调。
                    contactStore: contactStore,
                    preferences: preferences,
                    persistPreferences: persistPreferences,
                    // C9 接线：统计与设置页/采集流是同一份实例（桌面流不经
                    // CaptureSession，单独注入）。
                    usage: store.usage,
                    // 知识检索注入（独立复核补接线）：_buildCtx 每轮分析现查
                    // 同一份应用级 KbStore（CaptureSession.knowledgeRefsOf）。
                    knowledgeBase: kbStore,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(
                  store: store,
                  kbStore: kbStore,
                  contactStore: contactStore,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        // 场景选中态跟 store.scenarioId 走：本页/引导页/设置页写它，这里
        // 监听重建，选中态与持久化值永远同源（ValueNotifier 写入即通知，
        // 点卡片的视觉反馈不需要 setState）。
        listenable: store.scenarioId,
        builder: (context, _) {
          final current = Scenarios.byId(store.scenarioId.value);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 当前态说明条：「不选场景」的路径也给出明确事实——不强制选。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  current == null
                      ? '当前未指定场景（默认按「${Scenarios.chatCopilot.name}」执行）；点卡片切换，选择会记住。'
                      : '当前场景：${current.name}；点其他卡片切换，选择会记住。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: scenarios.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, index) => _ScenarioCard(
                    scenario: scenarios[index],
                    selected: scenarios[index].id == store.scenarioId.value,
                    onTap: () => _switchScenario(scenarios[index].id),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 一张场景卡：名称 + 一句话描述 + 采集目标标签（[ScenarioTemplate.platforms]）。
/// 本轮升级为可选：[selected] 高亮当前场景（主色描边 + 「当前场景」徽标），
/// [onTap] 由页面写入 store——布局不重排，只加视觉层与点击层。
class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.selected,
    this.onTap,
  });

  final ScenarioTemplate scenario;

  /// 当前场景 = SettingsStore.scenarioId 持久化值命中的那张卡。
  final bool selected;

  /// 点击切换场景（写 store + 落盘，见 ScenarioListPage._switchScenario）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      // 选中态描边：主色 2px；未选中给透明描边保持同宽度不跳版。
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide(color: scheme.surfaceContainerHighest),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      scenario.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  // 选中徽标：明确的当前态（视觉反馈的一部分）。
                  if (selected)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius:
                            const BorderRadius.all(Radius.circular(999)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check,
                              size: 13, color: scheme.onPrimaryContainer),
                          const SizedBox(width: 3),
                          Text(
                            '当前场景',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(scenario.description),
              if (scenario.platforms.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final platform in scenario.platforms)
                      _platformTag(platform, scheme),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _platformTag(String label, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: const BorderRadius.all(Radius.circular(999)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
}

/// 「页面所有者构造与 dispose」约定的 main 接线落点（#13）：路由装配、页面
/// 首次 build 之前经 [create] 构造控制器，路由退场时 dispose 归还。
///
/// 为什么控制器不交给页面自己 dispose：实测三个管理页都只自理内部资源——
/// KnowledgePage 的 State.dispose 摘监听 + 释放搜索框（knowledge_page.dart:
/// 66-70）、ExpertsPage 释放搜索框（experts_page.dart:34-37）、PersonasPage
/// 连页面级 dispose 都没有——没有一个碰注入的控制器。「页面 dispose 自理」
/// 在代码里的真实形状是「页面只管自己的输入框」，控制器收尾就落在所有者
/// （本宿主）手里；这里不兜住，每次进出页面都会漏一批 ValueNotifier。
///
/// main 不代持：控制器实例只活在本宿主的 State 里，没有应用级持有者；pop
/// 即回收，下次 push 重新构造并重新 load——页面每次进来看到的都是盘上的
/// 最新状态。
///
/// 已知微风险（留 fixer/复核评判）：Experts/Personas 的 load() 是异步收尾，
/// 若 push 后在 shared_preferences 平台通道返回**之前**就 pop，load 会在
/// dispose 之后写 notifier——PersonasController.load 内部全吞
/// （personas_controller.dart:360-381 的 try/catch），ExpertsController.load
/// 的收尾赋值在 try 外（experts_controller.dart:1121），debug 模式会抛未处理
/// 异步错误。人手触发不了这个窗口（首次启动后 getInstance 已缓存，load 的
/// 续体都是微任务级），根治要改控制器的可取消 load，不在本文件权限内。
class _PageHost<C> extends StatefulWidget {
  const _PageHost({required this.create, required this.builder});

  /// push 装配时构造控制器（「入口 push 时构造」）。Experts/Personas 的
  /// 存档读取是异步 load，由 create 闭包以 `..load()` 触发（级联返回自身）。
  final C Function() create;

  /// 用构造好的控制器装配页面。
  final Widget Function(BuildContext context, C controller) builder;

  @override
  State<_PageHost<C>> createState() => _PageHostState<C>();
}

class _PageHostState<C> extends State<_PageHost<C>> {
  late final C _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.create();
  }

  @override
  void dispose() {
    // 三个控制器的收尾都是无参 dispose()（knowledge_controller.dart:418、
    // experts_controller.dart:1170、personas_controller.dart:650）。泛型拿
    // 不到成员签名，dynamic 派发一次；哪天签名漂移，进出资料页会立刻炸
    // 出来，不会静默漏。
    (_controller as dynamic).dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// 设置页：[JevConfig] 五项 + 服务商预设下拉 + 关系描述 + 悬浮窗开关；保存
/// 按钮把内存改好的整包设置写盘（[SettingsStore.save]）。「连通性测试」
/// 跑一次真实的 ping 往返。
///
/// 服务商下拉（p0-plan ①）只做「起点」：选中即把预设地址回填进地址框，
/// 地址框仍可手改——下拉回显的永远是「当前地址属于哪档」，手改成自定义
/// 地址就落回「自定义」，不会锁死。
///
/// #13 接线：页顶新增「资料」入口组（知识库 / 专家团 / 人设库）。控制器不
/// 在本页持有——三个入口的 push 都经 [_PageHost] 当场构造、路由退场 dispose；
/// 本页只提供构造它们所需的 [kbStore] 与 [contactStore]。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.kbStore,
    this.contactStore,
  });

  /// 设置的内存态与落盘目标。测试用的是输入框里的**当前值**——所见即所测，
  /// 不必先点保存。
  final SettingsStore store;

  /// #13 应用级知识库存档（根 State initState 构造）：知识库入口 push 时包
  /// 进 KnowledgeController。必填——管理页没有存档就无从谈起，缺了在编译期
  /// 报错好过运行时收起入口装没有。
  final KbStore kbStore;

  /// #6 联系人档案（可选——直接 pump 本页的测试不传）：专家团「套用为联系
  /// 人人设」的写入口（ContactStorePersonaSink）。不传时 ExpertsController
  /// 的 contactSink 缺位，专家页对套用动作如实提示「未接线」而不是假装成功。
  final ContactStore? contactStore;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _replyKey;
  late final TextEditingController _replyModel;
  late final TextEditingController _style;
  late final TextEditingController _relationship;

  /// 悬浮窗开关的编辑值：进 [_save] 时才写回 [SettingsStore.overlayEnabled]。
  late bool _overlayEnabled;

  /// B8 候选展示模式的编辑值：进 [_save] 时写回 [SettingsStore.displayMode]。
  /// 取值 [SettingsStore.displayModePrimary] / [SettingsStore.displayModeAll]。
  late String _displayMode;

  bool _testing = false;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.store.config.value;
    _baseUrl = TextEditingController(text: c.replyBaseUrl);
    _replyKey = TextEditingController(text: c.replyKey);
    _replyModel = TextEditingController(text: c.replyModel);
    _style = TextEditingController(text: c.style);
    _relationship =
        TextEditingController(text: widget.store.relationship.value);
    _overlayEnabled = widget.store.overlayEnabled.value;
    _displayMode = widget.store.displayMode.value;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _replyKey.dispose();
    _replyModel.dispose();
    _style.dispose();
    _relationship.dispose();
    super.dispose();
  }

  /// 把输入框当前值合进现有配置（copyWith 只动回复三项 + style；判断四
  /// 字段由 [JudgeRouteSection] 即时写 config.value，**不经这里合并**——
  /// 否则保存按钮会用 initState 时的陈旧控制器值覆盖判断区的即时写入，
  /// 见模型路由区接线注释）。base/key/model 按旧仓库 Prefs setter 的习惯
  /// trim，style 是用户自己的话，原样保留。copyWith 的 null 表示「不动」，
  /// 所以空串也要显式传。judgeKey 等未列出的字段原样不丢。
  JevConfig _configFromFields() => widget.store.config.value.copyWith(
        replyBaseUrl: _baseUrl.text.trim(),
        replyKey: _replyKey.text.trim(),
        replyModel: _replyModel.text.trim(),
        style: _style.text,
      );

  Future<void> _save() async {
    widget.store.config.value = _configFromFields();
    // 关系描述按旧仓库 Prefs setter 的习惯原样保存（不 trim），修剪留给使用方。
    widget.store.relationship.value = _relationship.text;
    widget.store.overlayEnabled.value = _overlayEnabled;
    // B8 展示模式与悬浮窗开关同一节奏：保存才提交，采集页/桌面页与悬浮窗
    // 读的都是这份 notifier，下一轮渲染/下一批候选生效。
    widget.store.displayMode.value = _displayMode;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.store.save();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('已保存（重启后自动恢复）')),
        );
    } catch (e) {
      // 写盘失败不影响本次运行：内存里的新值已经生效。
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('已生效但写盘失败：$e')),
        );
    }
  }

  Future<void> _runPing() async {
    setState(() {
      _testing = true;
      _result = null;
      _error = null;
    });
    try {
      final reply = await ReplyClient(_configFromFields()).ping();
      if (!mounted) return;
      setState(() {
        _result = reply.isEmpty ? '（模型返回了空内容）' : reply;
      });
    } on ApiException catch (e) {
      // 错误文案原样显示：路由 + HTTP 状态 + 响应体前 120 字（见 ApiException）。
      if (!mounted) return;
      setState(() {
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  /// C9 统计卡：四条路由一行一个 —— 大字是累计口径（随设置持久化），小字
  /// 是本次会话口径（启动清零）。数字在打开本页 / 点重置时读取一次：后台
  /// 采集链路的增量要重进本页才刷新（UsageStats 没有通知机制，见其读数注释）。
  Widget _usageCard() {
    final usage = widget.store.usage;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final route in UsageRoute.values) ...[
              Text(
                '${route.label}：调用 ${usage.calls(route)}'
                ' · 失败 ${usage.failures(route)}'
                ' · 缓存命中 ${usage.cacheHits(route)}',
              ),
              Text(
                '本次会话：调用 ${usage.calls(route, session: true)}'
                ' · 失败 ${usage.failures(route, session: true)}'
                ' · 缓存命中 ${usage.cacheHits(route, session: true)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _resetUsage,
                icon: const Icon(Icons.restart_alt),
                label: const Text('重置统计'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 重置统计：两个口径清零并刷新卡片，随后尽力把清零后的累计口径写盘。
  /// 统计是次要数据，写盘失败不弹打扰性提示 —— 下次保存设置时会再写一次。
  Future<void> _resetUsage() async {
    setState(() => widget.store.usage.reset());
    try {
      await widget.store.save();
    } catch (_) {
      // 写盘失败仅影响持久化：内存里已清零，下次保存设置时补写。
    }
  }

  // -------------------------------------------------------- 注入采集(实验)

  /// 注入采集 App 名的显示映射（清单在 [SettingsStore.injectionScopedPackages]，
  /// 与 Kotlin HookTargets.SCOPED 互钳）；不在映射里的包名原样显示。
  static const Map<String, String> _injectionAppLabels = {
    'org.telegram.messenger': 'Telegram',
  };

  /// M0「注入采集(实验)」区（root-module-design.md §4-M0：设置页逐 App 开关 +
  /// 「已连接」状态；§3.3-3/4 的合规硬约束）。
  ///
  /// - 逐 App 开关：渲染源 [SettingsStore.injectionScopedPackages]（当前仅
  ///   Telegram 一项，HookTargets 同值清单），默认关——映射里没有的包一律按
  ///   关处理（fail-closed）。开关变更即时写 store（[_setInjectionEnabled]，
  ///   JudgeRouteSection 同款即时写风格，不经保存按钮合并）；原生侧镜像由
  ///   store 的变更监听随既有 configure 推送路径下发，本区不直接碰通道。
  /// - 已连接状态行：M0 **恒显「未检测到注入模块」**——本仓库此刻没有随附
  ///   注入模块（无任何 xposed meta-data/xposed_init/xposedscope，M0 验收④），
  ///   不假装已连接；M1 起接 bridge 的 hello 账本（BridgeLedger）后改为按
  ///   账本现状回显。
  /// - 账号风险声明按 §3.3-4 原文呈现（微信条款摘要 + 「只读、不发消息」
  ///   不能推导出不会封号；Telegram 无条款原文，按同一精神写同类风险句，
  ///   不编造条款号）。
  Widget _injectionSection() {
    final enabled = widget.store.injectionEnabled.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('注入采集(实验)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        // 状态行（M0 恒真值，见方法注释）。
        Text('未检测到注入模块', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        for (final pkg in SettingsStore.injectionScopedPackages)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            key: ValueKey('injection-switch-$pkg'),
            title: Text(_injectionAppLabels[pkg] ?? pkg),
            subtitle: Text(pkg),
            value: enabled[pkg] ?? false,
            onChanged: (v) => _setInjectionEnabled(pkg, v),
          ),
        const SizedBox(height: 4),
        // 账号风险原文（§3.3-4「不可谈判，全部沿用 legacy 硬约束」）。
        Text(
          '账号风险声明（原文）：微信协议 8.2.1.4–8.2.1.7 限制未授权插件接入'
          '与对运行数据的读取，8.5.1 处置含功能限制与账号封禁；「只读、不发消息」'
          '不能推导出不会封号。Telegram：同类风险适用于任何被注入的 App。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 注入开关的单一写入口：即时写 store 的 [SettingsStore.injectionEnabled]
  /// notifier（JudgeRouteSection 同款即时写风格——内存即时生效，不经保存
  /// 按钮合并，落盘走设置页既有保存按钮的整包写盘；重启未落盘即回默认
  /// 全关，fail-closed 方向安全）。store 构造时挂的变更监听负责把新值随
  /// 既有 configure 推送路径下发（开关镜像契约），本方法不直接碰通道。
  void _setInjectionEnabled(String pkg, bool enabled) {
    final next = Map<String, bool>.of(widget.store.injectionEnabled.value)
      ..[pkg] = enabled;
    setState(() => widget.store.injectionEnabled.value = next);
  }

  // ------------------------------------------------------------ 资料入口组

  /// 知识库（#13）：控制器包住应用级那份 [KbStore]（构造在根 State
  /// initState，见 _ChartoolsAppState.kbStore），路由退场由 [_PageHost]
  /// dispose 控制器——KbStore 是应用级存档，**不**随页面销毁。
  /// KnowledgePage 是 body-only 组件（knowledge_page.dart:12），路由外壳的
  /// Scaffold + AppBar 由接线方（这里）补上，与另外两页自带的外壳对齐。
  void _openKnowledge() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PageHost<KnowledgeController>(
        create: () => KnowledgeController(widget.kbStore),
        builder: (_, controller) => Scaffold(
          appBar: AppBar(
            title: const Text('知识库'),
            // 文档导入入口（本轮接线，外部审阅 ②）：粘贴文本 → 解析预览 →
            // 入库 → 对账全在 knowledge_page.dart 的 showKnowledgeImportSheet；
            // 动作挂这里是因为页面本体 body-only，AppBar 归路由外壳——
            // 空状态文案指向同一入口。
            actions: [
              IconButton(
                tooltip: '导入文档笔记',
                icon: const Icon(Icons.upload_file_outlined),
                onPressed: () => showKnowledgeImportSheet(context, controller),
              ),
            ],
          ),
          body: KnowledgePage(controller: controller),
        ),
      ),
    ));
  }

  /// 专家团（#13）：套用写入口按 experts_controller.dart 类文档的接线口径
  /// 组装——SettingsStyleSink 写设置里的 style（本页的 [widget.store]），
  /// ContactStorePersonaSink 覆写联系人档案的 persona；未传联系档案时 sink
  /// 缺位，专家页对套用动作如实提示「未接线」。`..load()` 读我的库与已装
  /// 资产包（shared_preferences），坏档/通道缺失按空清单继续。
  void _openExperts() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PageHost<ExpertsController>(
        create: () => ExpertsController(
          styleSink: SettingsStyleSink(widget.store),
          contactSink: widget.contactStore == null
              ? null
              : ContactStorePersonaSink(widget.contactStore!),
        )..load(),
        builder: (_, controller) => ExpertsPage(controller: controller),
      ),
    ));
  }

  /// 人设库（#13）：列表经 entries notifier 监听，load 完成即刷新。套用
  /// 动作（本轮接线，外部审阅 ①）的两个落点按 experts_controller.dart 类
  /// 文档的同一接线口径组装——SettingsStyleSink 写设置里的 style（本页的
  /// [widget.store]），ContactStorePersonaSink 覆写联系人档案的 persona；
  /// 未传联系档案时 contactSink 缺位，人设页对相应动作如实提示「未接线」。
  /// 人设套用只写这两个 sink，不搬数据（人设库与专家库各自持数据）。
  void _openPersonas() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PageHost<PersonasController>(
        create: () => PersonasController(
          styleSink: SettingsStyleSink(widget.store),
          contactSink: widget.contactStore == null
              ? null
              : ContactStorePersonaSink(widget.contactStore!),
        )..load(),
        builder: (_, controller) => PersonasPage(controller: controller),
      ),
    ));
  }

  /// 迁移旧版数据（fixer 补接线）：MigrationPage 是 body-only 组件
  /// （migration_page.dart:23），路由外壳 Scaffold + AppBar 由这里补上，与
  /// 知识库页同款。控制器包住应用级那份 [widget.kbStore]——迁移目标库与
  /// 知识库页是同一份实例（migration_controller.dart:26 的口径），迁进来的
  /// 笔记/联系人退出本页后在知识库页当场可见；push 时经 [_PageHost] 构造、
  /// 退场 dispose（dispose 收控制器自己的三个 ValueNotifier，KbStore 不随
  /// 页面销毁）。无异步 load（预览是即时的），不需要 `..load()`。
  void _openMigration() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PageHost<MigrationController>(
        create: () => MigrationController(store: widget.kbStore),
        builder: (_, controller) => Scaffold(
          appBar: AppBar(title: const Text('迁移旧版数据')),
          body: MigrationPage(controller: controller),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // #13 资料入口组（任务 1）：放页顶——知识页的「一等页面」定位
          // （knowledge_page.dart:5-6）要求管理面不藏在模型参数里。三个入口
          // 都不在这里构造控制器：push 交给 [_PageHost] 当场构造、退场即收。
          Text('资料', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('知识库'),
            subtitle: const Text('笔记、联系人档案与检索评测的统一管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openKnowledge,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.groups_outlined),
            title: const Text('专家团'),
            subtitle: const Text('浏览专家目录与资产包，套用为全局风格或联系人人设'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openExperts,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.face_outlined),
            title: const Text('人设库'),
            subtitle: const Text('维护人设卡，支持导入 Character Card（CCV2）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openPersonas,
          ),
          // 迁移入口（fixer 补接线）：同属资料管理面——旧版数据的一次性迁入，
          // 与上面三个管理页同组、不进模型参数也不占首页。
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.move_down_outlined),
            title: const Text('迁移旧版数据'),
            subtitle: const Text('把旧版导出的笔记/联系人 JSON 迁入知识库'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openMigration,
          ),
          const SizedBox(height: 12),
          Text('模型路由', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '配置保存到本机，重启后自动恢复。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          // 服务商预设（p0-plan ①）：选中即回填下方地址框。value 按地址框
          // 当前内容反查（ModelPresets.byBaseUrl），所以手动改地址后下拉会
          // 自己落到「自定义」——预设是起点，不锁死。key 是否已填驱动提醒行。
          ModelPresetPicker(
            value: ModelPresets.byBaseUrl(_baseUrl.text.trim()),
            hasKey: _replyKey.text.trim().isNotEmpty,
            onChanged: (preset) =>
                setState(() => _baseUrl.text = preset.replyBaseUrl),
          ),
          const SizedBox(height: 12),
          // 两个输入框 onChanged 触发重绘：让下拉回显与预设提示跟手。
          _field(
            '回复接口地址（到 /v1 为止）',
            _baseUrl,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
          ),
          _field(
            '回复接口 API Key',
            _replyKey,
            obscure: true,
            onChanged: (_) => setState(() {}),
          ),
          _field('回复模型', _replyModel),
          // P0 判断路由接线（settings_page.dart:10-15 头注的三步，本轮执行）：
          // 判断服务商/地址/Key/模型四字段由 JudgeRouteSection 即时写
          // config.value（内存生效、保存按钮落盘——与悬浮窗开关同节奏），
          // 旧的单行判断模型输入框已删，避免与本区双写同一字段；
          // _configFromFields 同步去掉 judgeModel 合并行——否则保存按钮会用
          // initState 时的陈旧控制器值覆盖判断区的即时写入。onEdited 触发
          // 宿主重绘，让页面上依赖 config 的回显跟手。
          JudgeRouteSection(
            config: widget.store.config,
            onEdited: () => setState(() {}),
          ),
          _field('语气 / 人设备注', _style, maxLines: 3),
          const SizedBox(height: 8),
          Text('关系与悬浮窗', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _field('与对方的关系（进提示词）', _relationship),
          // 悬浮窗开关与采集侧共用同一份 notifier（SettingsStore.overlayEnabled，
          // 采集流水线直接消费，见 capture_session.dart）：这里保存后立即生效。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('悬浮窗开关'),
            subtitle: const Text('有新候选时在聊天应用上方弹出；与采集助手页的开关是同一份'),
            value: _overlayEnabled,
            onChanged: (v) => setState(() => _overlayEnabled = v),
          ),
          // B8「一条推荐+两条备选」的展示模式开关：开 = 主推排序第一张大卡、
          // 备选折叠为两行小字（默认）；关 = 全部候选平铺。候选页与悬浮窗
          // 同构读这一份值。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('主推模式（一条推荐+备选折叠）'),
            subtitle: const Text('开：排序第一张大卡为主推，备选折叠两行小字、点击展开；关：全部候选平铺。'),
            value: _displayMode == SettingsStore.displayModePrimary,
            onChanged: (v) => setState(() => _displayMode = v
                ? SettingsStore.displayModePrimary
                : SettingsStore.displayModeAll),
          ),
          const SizedBox(height: 12),
          // M0「注入采集(实验)」区（root-module-design.md §4-M0）：逐 App 开关
          // + 状态行 + 账号风险原文，见 [_injectionSection] 的注释。
          _injectionSection(),
          const SizedBox(height: 8),
          // C9 调用统计卡：judge/reply/review/polish 四行数字（累计 + 本次
          // 会话两个口径）+ 重置按钮。统计是用户自己的数据（p0-plan ②），
          // 可查看、可清零；清零随下次写盘持久化。
          Text('调用统计', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '累计口径随设置保存，「本次会话」自应用启动起计。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _usageCard(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _testing ? null : _runPing,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: const Text('连通性测试'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_result != null)
            _resultCard(
              '模型回复',
              _result!,
              Theme.of(context).colorScheme.primaryContainer,
            ),
          if (_error != null)
            _resultCard(
              '连接失败',
              _error!,
              Theme.of(context).colorScheme.errorContainer,
            ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          maxLines: maxLines,
          keyboardType: keyboardType,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _resultCard(String title, String text, Color background) => Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SelectionArea(child: Text(text)),
            ],
          ),
        ),
      );
}
