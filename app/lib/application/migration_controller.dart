/// legacy 迁移控制器（W6 app 层）—— MigrationPage 的数据面。
///
/// 分层：core 导入器（`legacy_importer.dart` 的纯函数：parseLegacyXxx /
/// collectLegacyBundle / buildMigrationPreview）→ 本控制器（app：Notifier
/// 状态面 + 勾选集合 + 确认落盘编排）→ MigrationPage（ui：粘贴/预览/勾选/
/// 结果展示）。
///
/// 「持 LegacyImporter + KbStoreSink」的落法：core 里没有名为 LegacyImporter
/// 的类——导入器是一组纯函数，本类直接调用（不包壳）；KbStoreSink 是落盘
/// 通路，构造注入（缺省用当前 store 现造一个），测试可注入替身。
///
/// 跨段的「失败即停」在这里落实（契约分工见 legacy_importer.dart:930-949
/// 与 migration_sink.dart 头注释）：notes → contacts → personas 顺序执行，
/// 前一段失败后，后续段不再执行，对账里如实标记「未执行」，绝不把没跑的
/// 段算成成功或失败。
///
/// **main 接线留 fixer 阶段**：本文件不 import main.dart，也不自建 KbStore
/// ——构造注入由接线完成（生产路径给带 archivePath 的 KbStore 实例）。
library;

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';

/// legacy 迁移控制器。
class MigrationController {
  /// [store] 是迁移的目标库（与知识库页/采集注入同一份实例）；[sink] 缺省
  /// 现造 [KbStoreSink(store)]，测试可注入替身。
  MigrationController({required KbStore store, KbStoreSink? sink})
      : _store = store,
        _sink = sink ?? KbStoreSink(store);

  final KbStore _store;
  final KbStoreSink _sink;

  /// 是否有落盘在途（confirm 的重入闸；页面另有按钮级防抖）。
  bool _confirming = false;

  // ------------------------------------------------------------- 状态面

  /// 当前预览（null = 还没解析过）。纯数据，无副作用——放多久都不落盘。
  final ValueNotifier<MigrationPreview?> preview = ValueNotifier(null);

  /// 勾选集合。键 = `'文件名#源下标'`（[MigrationItem.file] + [MigrationItem.index]，
  /// 见 [MigrationController.keyOf]）。默认勾选 = 全部 insert 状态；重复项不可勾（无损跳过，
  /// 再写一遍只会翻倍）；冲突项默认不勾，用户逐条点名才算「仍导入」裁决
  /// （legacy_importer.dart:802-804 的契约）。
  final ValueNotifier<Set<String>> selectedKeys = ValueNotifier(const <String>{});

  /// 最近一次确认的对账（null = 还没确认过）；结果页直接消费。
  final ValueNotifier<MigrationApplyReport?> lastReport = ValueNotifier(null);

  // ------------------------------------------------------------ 预览

  /// 解析预览：用户粘贴的三段 legacy JSON 文本 → [MigrationPreview]。
  ///
  /// 某段为 null/空白 → 按 collectLegacyBundle 的既定语义视为「迁移包里没有
  /// 这个文件」，文件级 problem、其余照常。重复/冲突判定的「既有侧」从当前
  /// KbStore **现查**（预览是即时快照，落盘前的库变化会在下一次 loadTexts
  /// 里如实反映）；人设段的既有索引留空——新版暂无人设存储可比对，包内
  /// 去重照常生效。
  void loadTexts({
    String? notesJson,
    String? contactsJson,
    String? personasJson,
  }) {
    final bundle = collectLegacyBundle(
      notesJson: _blankToNull(notesJson),
      contactsJson: _blankToNull(contactsJson),
      personasJson: _blankToNull(personasJson),
    );
    final existing = LegacyExistingIndex.fromData(
      notes: [for (final t in _store.notes()) t.note],
      contacts: _store.contacts(),
    );
    preview.value = buildMigrationPreview(bundle, existing: existing);
    selectedKeys.value = _defaultSelection(preview.value!);
    lastReport.value = null;
  }

  /// 空白文本 → null（文本框留空 = 没给这个文件，与「粘贴了空串」同义）。
  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s;

  /// 默认勾选：全部 insert 状态（确认集的既定口径，legacy_importer.dart:805-816）。
  Set<String> _defaultSelection(MigrationPreview p) => <String>{
        for (final i in p.notes)
          if (i.status == MigrationStatus.insert) keyOf(i),
        for (final i in p.contacts)
          if (i.status == MigrationStatus.insert) keyOf(i),
        for (final i in p.personas)
          if (i.status == MigrationStatus.insert) keyOf(i),
      };

  /// 勾选键：'文件名#源下标'。源下标随明细走（[MigrationItem.index]），同一
  /// 文件内唯一；三类文件名互不相同，跨段也不撞。公开给页面用——勾选行的
  /// 选中态与 Widget Key 都要用同一把键。
  static String keyOf<T>(MigrationItem<T> item) => '${item.file}#${item.index}';

  // ------------------------------------------------------------ 勾选

  /// 是否可勾。重复项不可勾：内容已在库里（hash 全等），再写一遍只会翻倍，
  /// 「无损跳过」没有可裁决的东西；insert 与 conflict 都可勾——冲突项被点名
  /// 即用户裁决「仍导入」（覆盖/并存由 sink 的写入语义决定，明细里已写明）。
  bool isTickable<T>(MigrationItem<T> item) =>
      item.status != MigrationStatus.duplicate;

  /// 勾/去勾一条明细。重复项静默忽略（不可勾）。
  void setChecked<T>(MigrationItem<T> item, bool on) {
    if (!isTickable(item)) return;
    final next = Set.of(selectedKeys.value);
    if (on) {
      next.add(keyOf(item));
    } else {
      next.remove(keyOf(item));
    }
    selectedKeys.value = next;
  }

  /// 当前勾选的条数（结果页确认按钮的计数；重复项不可勾所以不在此列）。
  int get selectedCount => selectedKeys.value.length;

  // ------------------------------------------------------------ 确认落盘

  /// 确认落盘：**只落勾选项**。把勾选键映射回预览明细的实体（insert 全量默认
  /// 在勾选集里；conflict 只有被用户点名才进；duplicate 防御性再滤一道），
  /// 按 notes → contacts → personas 顺序交给 [KbStoreSink]，失败即停。
  /// 返回整包对账（成功 N/失败 M 的口径见 [MigrationApplyReport.describe]）。
  Future<MigrationApplyReport> confirm() async {
    if (_confirming) {
      // 重入防御：上一把还没落完。返回最近一次对账（没有则空账），不叠加写。
      return lastReport.value ?? _emptyReport();
    }
    final p = preview.value;
    if (p == null) return _emptyReport();
    _confirming = true;
    try {
      final keys = selectedKeys.value;
      final notes = [
        for (final i in p.notes)
          if (keys.contains(keyOf(i)) && i.status != MigrationStatus.duplicate)
            i.entity,
      ];
      final contacts = [
        for (final i in p.contacts)
          if (keys.contains(keyOf(i)) && i.status != MigrationStatus.duplicate)
            i.entity,
      ];
      final personas = [
        for (final i in p.personas)
          if (keys.contains(keyOf(i)) && i.status != MigrationStatus.duplicate)
            i.entity,
      ];

      // 段顺序执行，失败即停：前一段失败，后续段不执行，对账如实标记。
      final notesReport = await _sink.applyNotesDetailed(notes);
      final contactsReport = notesReport.ok
          ? await _sink.applyContactsDetailed(contacts)
          : _notExecuted('contacts.json', contacts.length,
              because: notesReport.error ?? 'notes 段失败');
      final personasReport = notesReport.ok && contactsReport.ok
          ? await _sink.applyPersonasDetailed(personas)
          : MigrationSegmentReport(
              label: 'personas.json',
              written: 0,
              skippedExisting: 0,
              pending: 0,
              deferred: personas.length,
              error: notesReport.ok
                  ? 'contacts 段失败，本段未执行'
                  : 'notes 段失败，本段未执行',
            );

      final report = MigrationApplyReport(
        notes: notesReport,
        contacts: contactsReport,
        personas: personasReport,
      );
      lastReport.value = report;
      return report;
    } finally {
      _confirming = false;
    }
  }

  /// 前段失败后「未执行」段的占位对账：pending = 全部确认条数（它们确实没
  /// 落盘），error 指明原因——绝不把没跑的段算成成功。
  MigrationSegmentReport _notExecuted(String label, int count,
      {required String because}) {
    return MigrationSegmentReport(
      label: label,
      written: 0,
      skippedExisting: 0,
      pending: count,
      error: '前段失败（$because），本段未执行',
    );
  }

  /// 没有预览时的空账（三段全零、全成功）——confirm 的防御分支用。
  MigrationApplyReport _emptyReport() => MigrationApplyReport(
        notes: const MigrationSegmentReport(
            label: 'notes.json',
            written: 0,
            skippedExisting: 0,
            pending: 0),
        contacts: const MigrationSegmentReport(
            label: 'contacts.json',
            written: 0,
            skippedExisting: 0,
            pending: 0),
        personas: const MigrationSegmentReport(
            label: 'personas.json',
            written: 0,
            skippedExisting: 0,
            pending: 0),
      );

  void dispose() {
    preview.dispose();
    selectedKeys.dispose();
    lastReport.dispose();
  }
}
