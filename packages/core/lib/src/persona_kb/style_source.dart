/// 人设卡的来源枚举（Dart 的 enum 必须是顶层声明）。
enum StyleSourceFrom {
  /// 两边都空：没有人设，提示词里不带这一段。
  none,

  /// 用的是全局 style（也就是当前生效的专家正文）。
  expert,

  /// 用的是这个聊天的联系人专用人设。
  contact,
}

/// 「哪段正文真的进了提示词」的唯一判定处。
///
/// 起草（ReplyClient.draftAsk）和复查（ReplyClient.review）以前各自写了一遍
/// `ctx?.contact?.persona ?: style`。两处是会漂的：谁改一处忘了另一处，复查
/// 就会拿着一张和起草不同的人设卡去判第 3、5 条标准。现在两处都走这里。
///
/// ## 优先级不改，但要说出来
///
/// 优先级是产品的：**联系人自己的专用人设压过全局 style（也就是专家正文）**。
/// 这没错——用户给某个具体的人写过脾气、边界，那句话比任何模板都更懂这个人。
///
/// 代价是：用户点过专家，只要那个聊天写过专用人设，提示词一个字节都不变，
/// 而界面上原本没有任何东西告诉他。这跟「点了用却没反应」在体感上是同一件事，
/// 所以 [Resolution.shadowed] 要被界面读出来，照着事实说话。
abstract final class StyleSource {
  /// 提示词里那张人设卡的来源（含被覆盖信息）。
  static Resolution resolve(String expert, String? contactPersona) {
    final fromContact = contactPersona?.trim();
    if (fromContact != null && fromContact.isNotEmpty) {
      return Resolution(
        text: fromContact,
        from: StyleSourceFrom.contact,
        shadowedExpert: expert,
      );
    }
    // 空串也原样返回：旧仓库 `?: style` 就是这个行为，换成 "" 会让一个
    // 只有空白的 style 从「原样进 PersonaCard」变成「空」，属于没人要求的变化。
    return Resolution(
      text: expert,
      from: expert.isEmpty ? StyleSourceFrom.none : StyleSourceFrom.expert,
    );
  }
}

/// 人设卡的来源解析结果。
class Resolution {
  const Resolution({
    required this.text,
    required this.from,
    this.shadowedExpert = '',
  });

  /// 真正进提示词的文本。专家正文原样（不 trim），联系人那句已 trim。
  final String text;
  final StyleSourceFrom from;

  /// 被联系人专用人设盖住的专家正文；没被盖住时为空串。
  final String shadowedExpert;

  /// 用户点过专家，但这个聊天里它没生效。界面用它决定要不要多讲一句。
  bool get shadowed =>
      from == StyleSourceFrom.contact && shadowedExpert.trim().isNotEmpty;
}
