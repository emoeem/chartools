import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 提示词分层锁 —— 文案按旧仓库 `jev/ReplyPrompt.kt` 逐字移植，测试按
/// `jev/ReplyPromptTest.kt` 的思路钉住。
///
/// 技能分层的最后一公里：匹配器说什么不重要，重要的是它真的进了提示词。
/// 这些断言不带 Prefs、不带网络，纯字符串拼装，所以分层顺序和文案都能
/// 在这里锁死。
void main() {
  ChatContext context({
    Contact? contact,
    List<LogEntry> history = const [],
    List<Note> notes = const [],
    List<SkillHit> skills = const [],
    String catalogue = '',
    Ledger? ledger,
  }) =>
      ChatContext(
        contact: contact,
        history: history,
        notes: notes,
        skills: skills,
        catalogue: catalogue,
        ledger: ledger,
      );

  ChatContext contextWithLedger(
    Ledger ledger, {
    List<LogEntry> history = const [],
    List<Note> notes = const [],
  }) =>
      context(history: history, notes: notes, ledger: ledger);

  SkillHit pirateHit() => const SkillHit(
        name: 'pirate-signature',
        body: '每条回复的最后一行必须单独是：——来自加勒比',
      );

  const pirateCatalogue = '<available_skills>\n<skill name="pirate-signature">'
      '<description>让候选回复带上海盗口吻</description></skill>\n</available_skills>';

  const addressNote = Note(id: 'n1', title: '住址', content: '他住在杭州');

  const lightAnalysis = Analysis(
    trueIntent: Choice(choice: 'casual_chat', confidence: 0.8),
    dangerLevel: Score(score: 1.0, confidence: 0.9, maxLevel: 9),
    sheNeeds: Choice(choice: 'nothing', confidence: 0.6),
    shouldReplyNow: 0.9,
    bestAction: Choice(choice: 'make_plan', confidence: 0.5),
    latencyMs: 10,
  );

  const tense9Analysis = Analysis(
    trueIntent: Choice(choice: 'casual_chat', confidence: 0.8),
    dangerLevel: Score(score: 9.0, confidence: 0.9, maxLevel: 9),
    sheNeeds: Choice(choice: 'nothing', confidence: 0.6),
    shouldReplyNow: 0.9,
    bestAction: Choice(choice: 'make_plan', confidence: 0.5),
    latencyMs: 10,
  );

  // 自动档用它决定收着：局势偏紧。
  const tenseAnalysis = Analysis(
    trueIntent: Choice(choice: 'vent_anger', confidence: 0.9),
    dangerLevel: Score(score: 7.0, confidence: 0.9, maxLevel: 9),
    latencyMs: 0,
  );

  const intimateAnalysis = Analysis(
    trueIntent: Choice(choice: 'intimate_roleplay', confidence: 0.8),
    dangerLevel: Score(score: 1.0, confidence: 0.9, maxLevel: 9),
    latencyMs: 0,
  );

  // 「哦 / 嗯哪」那一场：亲密场景里对方只是敷衍的一个字。
  const intimateFlatAnalysis = Analysis(
    trueIntent: Choice(choice: 'intimate_roleplay', confidence: 0.8),
    dangerLevel: Score(score: 2.0, confidence: 0.9, maxLevel: 9),
    sheNeeds: Choice(choice: 'nothing', confidence: 0.6),
    bestAction: Choice(choice: 'say_less', confidence: 0.6),
    latencyMs: 0,
  );

  // 真吵架：亲密场景也压不过高紧张。
  const intimateFightAnalysis = Analysis(
    trueIntent: Choice(choice: 'intimate_roleplay', confidence: 0.8),
    dangerLevel: Score(score: 8.0, confidence: 0.9, maxLevel: 9),
    bestAction: Choice(choice: 'say_less', confidence: 0.6),
    latencyMs: 0,
  );

  const intimateEngagementAnalysis = Analysis(
    trueIntent: Choice(choice: 'intimate_roleplay', confidence: 0.8),
    dangerLevel: Score(score: 1.0, confidence: 0.9, maxLevel: 9),
    sheNeeds: Choice(choice: 'engagement', confidence: 0.7),
    bestAction: Choice(choice: 'play_along', confidence: 0.7),
    latencyMs: 0,
  );

  // 判断把握不大的一轮：意图置信度低于阈值。
  const shakyAnalysis = Analysis(
    trueIntent: Choice(choice: 'casual_chat', confidence: 0.3),
    dangerLevel: Score(score: 1.0, confidence: 0.3, maxLevel: 9),
    sheNeeds: Choice(choice: 'nothing', confidence: 0.4),
    bestAction: Choice(choice: 'say_less', confidence: 0.3),
    latencyMs: 0,
  );

  // chat 协议对缺失的 confidence 填 0.0 —— 那是「没说」，不是「很低」。
  const unconfidentAnalysis = Analysis(
    trueIntent: Choice(choice: 'casual_chat', confidence: 0.0),
    dangerLevel: Score(score: 1.0, confidence: 0.0, maxLevel: 9),
    latencyMs: 0,
  );

  group('契约常量', () {
    test('技能正文上限 6000 字，低置信度门槛 0.5', () {
      // 两个常量是 reply_prompt.dart 的顶层常量，随 barrel 一并导出。
      expect(skillBodyMax, 6000);
      expect(lowConfidence, 0.5);
    });
  });

  group('knowledgeBlock / skillNote', () {
    test('空上下文什么都不说', () {
      expect(ReplyPrompt.knowledgeBlock('朋友', context(), 30), '');
      expect(ReplyPrompt.skillNote(context()), '');
      expect(ReplyPrompt.knowledgeBlock('朋友', null, 30), '');
      expect(ReplyPrompt.skillNote(null), '');
    });

    test('命中技能的正文整段引用进 user 提示词', () {
      final block =
          ReplyPrompt.knowledgeBlock('朋友', context(skills: [pirateHit()]), 30);
      expect(block, contains('技能「pirate-signature」的完整说明'));
      expect(block, contains('——来自加勒比'));
    });

    test('目录每轮都带上（本轮没命中正文就不能出现）', () {
      final ctx = context(catalogue: pirateCatalogue);
      final body = ReplyPrompt.knowledgeBlock('朋友', ctx, 30);
      expect(body, isNot(contains('——来自加勒比')));
      final note = ReplyPrompt.skillNote(ctx);
      expect(note, contains('<available_skills>'));
      expect(note, contains('pirate-signature'));
      expect(note, contains('你必须按那份说明来写'));
    });

    test('病态长正文截断而不是丢弃', () {
      final huge = 'x' * (skillBodyMax + 500);
      final block = ReplyPrompt.knowledgeBlock(
          '朋友',
          context(skills: [SkillHit(name: 'big', body: huge)]),
          30);
      expect(block, contains('技能「big」的完整说明'));
      expect(block, isNot(contains('x' * (skillBodyMax + 1))));
    });

    test('笔记与历史先于技能块', () {
      final ctx = context(
        notes: [addressNote],
        history: [
          const LogEntry(side: 'other', text: '在吗', ts: 1, app: 'com.tencent.tim'),
        ],
        skills: [pirateHit()],
      );
      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 30);
      expect(block.indexOf('杭州'), greaterThanOrEqualTo(0));
      expect(block.indexOf('杭州'), lessThan(block.indexOf('在吗')));
      expect(block.indexOf('在吗'), lessThan(block.indexOf('技能「')));
    });

    test('联系人背景生效', () {
      final ctx = context(
        contact: const Contact(
            id: 'c1', name: '张三', relationship: '同事', notes: '喜欢猫'),
      );
      expect(ReplyPrompt.knowledgeBlock('同事', ctx, 30), contains('喜欢猫'));
    });

    test('历史里的未知发言者不得印成对方', () {
      // 历史可以带未知侧（OCR 认不出分边）。不许重新贴成对方的标签：
      // 一屏自己的消息曾被当成 incoming 会话来判断并代答。
      final ctx = context(history: [
        const LogEntry(side: 'me', text: '我到楼下了', ts: 1, app: 'com.tencent.tim'),
        const LogEntry(side: '?', text: '好', ts: 2, app: 'com.tencent.tim'),
      ]);
      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 30);
      expect(block, contains('我：我到楼下了'));
      expect(block, contains('发言人不明：好'));
      expect(block, isNot(contains('对方：好')));
    });

    test('领域卡的常用说法与历史都要注明参考 ≠ 台词', () {
      // 「常用说法」把高频词喂进每一轮；历史里的「我：」行是模型自己发过的。
      // 两处都要注明「参考不是必背台词」，否则模型照着复读。
      final ctx = context(history: [
        const LogEntry(side: 'me', text: '跪好，现在报数', ts: 1, app: 'com.tencent.tim'),
        const LogEntry(
            side: 'other', text: '10 9 8 7 6 5 4 3 2 1 0', ts: 2, app: 'com.tencent.tim'),
      ]);
      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 30);
      expect(block, contains('不是每轮都要用一遍的台词'));
      expect(block, contains('里面已经说过的指令和说法不要重复'));
    });

    test('命中技能的参考资料带着自己的使用规则', () {
      // L3 语料的 references 按轮挑选，注入时必须带上「方法 ≠ 套路、
      // 不许问卷建档」的使用规则 —— 不重申这三条模型就会让用户去填问卷。
      final ctx = context(skills: [
        const SkillHit(
          name: 'goutoujunshi',
          body: 'SKILL BODY',
          extra: '【参考：07-沟通冲突与修复】\n吵架之后先修复情绪，再分清事实。\n',
        ),
      ]);
      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 30);
      expect(block, contains('【参考：07-沟通冲突与修复】'));
      expect(block, contains('提供方法，不照抄套路'));
      expect(block, contains('不要据此向用户提问或要求建档'));
      // 没挑到资源的技能不得多出参考资料段。
      final bare =
          ReplyPrompt.knowledgeBlock('朋友', context(skills: [pirateHit()]), 30);
      expect(bare, isNot(contains('【参考：')));
    });
  });

  group('knowledgeBlock 的风格样本', () {
    test('风格样本只进起草提示词，最多三条', () {
      // 少样本语音样本是「我怎么说话」，不是任何人的事实 —— 判断者读的
      // background 里不能出现。
      final samples = List.generate(
          4,
          (i) => Note(
              id: 's$i',
              title: '示例$i',
              content: '行吧，那就这样$i',
              type: noteTypeStyleSample));
      final ctx = context(notes: [addressNote, ...samples]);

      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 30);
      expect(block, contains('<user_style_examples>'));
      expect(block, contains('行吧，那就这样1'));
      expect(block, contains('以上仅是风格参考，不是当前对话内容'));
      // 用户写多少条，引用的都最多三条。
      expect('<user_style_examples>'.allMatches(block).length, 3);
      expect(block, isNot(contains('行吧，那就这样4')));

      final background = ctx.background('朋友');
      expect(background, contains('他住在杭州'));
      expect(background, isNot(contains('行吧，那就这样1')));
    });
  });

  group('knowledgeBlock 的台账', () {
    test('台账先于原始历史', () {
      // 台账是 S1 的全部主张：先给「既定情况」再给逐条原文，模型才不用
      // 从最后一屏重新猜称呼和线头。
      final ctx = contextWithLedger(
        const Ledger(address: '先生', relation: '主奴', boundaries: ['不提家人']),
        history: [
          const LogEntry(side: 'other', text: '过来', ts: 1, app: 'org.telegram.messenger'),
        ],
      );
      final prompt = ReplyPrompt.draftUserPrompt(
          '主奴', ctx, 30, null, PersonaCard.parse(''), '', '对方：过来', const [], 3);
      final at = prompt.indexOf;
      expect(at('【会话台账】'), greaterThanOrEqualTo(0));
      expect(at('【会话台账】'), lessThan(at('更早的聊天记录')));
      expect(at('称呼：先生'), lessThan(at('更早的聊天记录')));
      expect(at('更早的聊天记录'), lessThan(at('对方：过来')));
      expect(prompt, contains('取消不了上面的硬性禁止'));
    });

    test('只有台账也能撑起知识块', () {
      // 没有任何笔记、没有命中的技能、历史为 0，台账自己也要能把这一段
      // 撑起来 —— 否则新会话第一轮就白整理了。
      final block = ReplyPrompt.knowledgeBlock(
          '朋友',
          contextWithLedger(const Ledger(tone: '互相调侃，节奏很快')),
          30);
      expect(block, contains('以下是关于我和对方的背景与知识库'));
      expect(block, contains('互相调侃'));
    });

    test('没开台账的会话不多出「会话台账」字样', () {
      final ctx = context(
        notes: [addressNote],
        history: [
          const LogEntry(side: 'other', text: '在吗', ts: 1, app: 'com.tencent.tim'),
        ],
      );
      expect(ReplyPrompt.knowledgeBlock('朋友', ctx, 30), isNot(contains('会话台账')));
    });

    test('空台账不加任何东西', () {
      expect(
        ReplyPrompt.knowledgeBlock(
            '朋友', contextWithLedger(const Ledger()), 30),
        '',
      );
    });

    test('台账不进判断者读的 background', () {
      // 台账只进**回复**提示词。判断走 background，而 background 不认识
      // ledger —— 判断结果必须继续只看关系/笔记/摘要，否则会被一份模型
      // 自己写的摘要有偏差地带跑。
      final ctx = contextWithLedger(
        const Ledger(address: '先生', relation: '主奴'),
        notes: [addressNote],
      );
      final background = ctx.background('朋友');
      expect(background, contains('他住在杭州'));
      expect(background, isNot(contains('会话台账')));
      expect(background, isNot(contains('先生')));
    });
  });

  group('judgmentBlock', () {
    test('轻松判断给出闲聊指引', () {
      final block = ReplyPrompt.judgmentBlock(lightAnalysis);
      expect(block, contains('日常闲聊或打趣'));
      expect(block, contains('1/9'));
      expect(block, contains('什么都不需要'));
      expect(block, contains('约个具体的事'));
      expect(block, contains('局势轻松'));
      expect(block, isNot(contains('同样仅供参考')));
    });

    test('紧张判断换成去杠杆指引', () {
      final tense = ReplyPrompt.judgmentBlock(tense9Analysis);
      expect(tense, contains('局势偏紧'));
      expect(tense, isNot(contains('局势轻松')));
    });

    test('空判断什么都不加', () {
      expect(ReplyPrompt.judgmentBlock(null), '');
    });

    test('亲密场景不读成闲聊', () {
      final block = ReplyPrompt.judgmentBlock(intimateAnalysis);
      expect(block, contains('在按我们约好的关系/称呼往下推进这一场'));
      expect(block, contains('接着对方刚给的情境往下写'));
      expect(block, isNot(contains('不要沉重、不要突然深情')));
    });

    test('亲密场景带推进规则而不是复读仪式', () {
      // 实测整场复读「跪好 / 报数 / 请安」——「接着往下写」不定义清楚，
      // 模型就会读成「再发一遍指令」，所以推进的定义必须落在亲密分支里。
      final block = ReplyPrompt.judgmentBlock(intimateAnalysis);
      expect(block, contains('往前走一步'));
      expect(block, contains('一整场只说一次'));
      expect(block, contains('接住那个回答'));
      expect(block, isNot(contains('局势偏紧')));
    });

    test('敷衍的一个字不是加码的理由', () {
      // system 层的规则任何分支绕不开；亲密分支里的同一个例外也要写明，
      // 否则它自己那支就在说反话（「接着对方刚给的情境往下写」）。
      final sys = ReplyPrompt.systemPrompt(3);
      expect(sys, contains('不要顺着上一轮继续加码'));
      expect(sys, contains('敷衍'));

      final block = ReplyPrompt.judgmentBlock(intimateFlatAnalysis);
      expect(block, contains('先停下来确认对方怎么了'));
      expect(block, contains('接着对方刚给的情境往下写'));
    });

    test('真实冲突压过场景', () {
      // 亲密场的局势解读不是无视紧张度的许可证。
      final block = ReplyPrompt.judgmentBlock(intimateFightAnalysis);
      expect(block, contains('局势偏紧'));
      expect(block, isNot(contains('接着对方刚给的情境往下写')));
    });

    test('新判断结果读作句子而不是键', () {
      final block = ReplyPrompt.judgmentBlock(intimateEngagementAnalysis);
      expect(block, contains('接着对方的设定往下写'));
      expect(block, contains('被接住、顺着这个情境继续'));
      expect(block, isNot(contains('play_along')));
      expect(block, isNot(contains('engagement')));
    });

    test('低置信度判断不主导局势', () {
      // 拿不准的判断被当成事实念出来，比没有判断更糟：轻松闲聊会被写成
      // 危机公关。低于阈值时只留一句弱参考，不给局势定性。
      final block = ReplyPrompt.judgmentBlock(shakyAnalysis);
      expect(block, contains('把握不大'));
      expect(block, contains('按字面承接'));
      expect(block, contains('同样仅供参考'));
      expect(block, isNot(contains('局势轻松')));
      expect(block, isNot(contains('什么都不需要')));
      expect(block, isNot(contains('日常闲聊或打趣')));
    });

    test('缺 confidence 不当低置信度', () {
      // 把「没说」当「很低」，会让一个习惯省略字段的模型每一轮都被降级。
      final block = ReplyPrompt.judgmentBlock(unconfidentAnalysis);
      expect(block, isNot(contains('把握不大')));
      expect(block, contains('日常闲聊'));
    });

    test('置信度恰好在门槛上时按正常处理', () {
      final borderline = unconfidentAnalysis.copyWith(
          trueIntent: const Choice(choice: 'casual_chat', confidence: 0.5));
      final block = ReplyPrompt.judgmentBlock(borderline);
      expect(block, isNot(contains('把握不大')));
      expect(block, contains('日常闲聊'));
    });

    test('判断认为不急着回时带一句弱提示', () {
      final block = ReplyPrompt.judgmentBlock(
          lightAnalysis.copyWith(shouldReplyNow: 0.3));
      expect(block, contains('现在可以不急着回，或换个方式回应'));
    });
  });

  group('intensityBlock', () {
    test('自动档 + 高紧张收着：说明是自动选的，且禁止推进动作', () {
      final soft = ReplyPrompt.intensityBlock(Intensity.auto, tenseAnalysis);
      expect(soft, contains('收着'));
      expect(soft, contains('自动档'));
      expect(soft, contains('不要发出邀约'));
    });

    test('手选加码 × 偏冷：不推翻用户，但第一条留作承接', () {
      final forward =
          ReplyPrompt.intensityBlock(Intensity.forward, tenseAnalysis);
      expect(forward, contains('加码'));
      expect(forward, contains('仍按这个选择写'));
      expect(forward, contains('第一条留作承接'));
    });

    test('手选收着不带加码的风险句，也不说自动', () {
      final manualSoft =
          ReplyPrompt.intensityBlock(Intensity.soft, tenseAnalysis);
      expect(manualSoft, contains('以稳妥承接为主'));
      expect(manualSoft, isNot(contains('仍按这个选择写')));
      expect(manualSoft, isNot(contains('自动档')));
    });

    test('自动档 + 判断为 null 时为空串（默认轮次兼容锁）', () {
      // 自动档解析成「自然」时返回空串 —— 默认轮次的提示词和没有档位
      // 功能之前逐字节一致。
      expect(ReplyPrompt.intensityBlock(Intensity.auto, null), '');
      expect(ReplyPrompt.intensityBlock(Intensity.natural, null), '');
    });

    test('加码 × 不偏冷时没有风险句', () {
      final forward =
          ReplyPrompt.intensityBlock(Intensity.forward, lightAnalysis);
      expect(forward, contains('优先给能推进的话'));
      expect(forward, isNot(contains('仍按这个选择写')));
    });
  });

  group('styleBlock / cautionBlock', () {
    test('空风格什么都不加', () {
      expect(ReplyPrompt.styleBlock(''), '');
      expect(ReplyPrompt.styleBlock('   '), '');
    });

    test('自由文本逐字引用（改造前的字节）', () {
      expect(
        ReplyPrompt.styleBlock('我们在暧昧期，喜欢互怼'),
        '我想要的语气和人设（比上面的默认风格优先，但硬性禁止仍然有效）：\n'
        '我们在暧昧期，喜欢互怼\n\n',
      );
    });

    test('人设卡以卡的形式引用，且不再宣称禁令有效', () {
      final card = PersonaCard.parse('称呼：先生\n关系：主奴\n语域：亲密\n硬边界：不要提家人');
      final block = ReplyPrompt.styleBlock(
        card.promptText(),
        registerOpen: card.registerOpen,
      );
      expect(block, contains('称呼：先生'));
      expect(block, contains('硬边界'));
      expect(block, contains('安全红线仍然有效'));
      expect(block, isNot(contains('但硬性禁止仍然有效')));
    });

    test('无 caution 时为空', () {
      expect(ReplyPrompt.cautionBlock(''), '');
      expect(ReplyPrompt.cautionBlock('   '), '');
    });

    test('caution 提醒写进提示词且不被埋掉', () {
      final block = ReplyPrompt.cautionBlock(
          '出现了「威胁」，确认这是双方自愿、不是被推着走');
      expect(block, contains('需要留神的信号'));
      expect(block, contains('不要顺着这些方向推'));
    });
  });

  group('systemPrompt', () {
    test('起草提示词禁掉那次真的发回来的卑微台词', () {
      // 旧版让一条候选「简短低姿态」，暧昧线程真回来过一句
      // 「主人不要伤害我？」—— 模型一字不差照办了。禁令与 JSON 计数
      // 都必须留在提示词里。
      final sys = ReplyPrompt.systemPrompt(3);
      expect(sys, isNot(contains('低姿态')));
      expect(sys, contains('不要卑微求饶'));
      expect(sys, contains('不要角色扮演式台词'));
      expect(sys, contains('「主人」'));
      expect(sys, contains('3 个对象'));
      // 一条候选仍然要推进线程，只是不许卑微。
      expect(sys, contains('推进话题'));
    });

    test('system 提示词反模板节奏与自检', () {
      // 实测「AI味十足」：每条都是「命令＋规矩＋下一步」的固定节奏。
      // 反模板与自检放在 system 层，任何分支、任何人设卡都绕不开。
      final sys = ReplyPrompt.systemPrompt(3);
      expect(sys, contains('同一个模子'));
      expect(sys, contains('输出前自检'));
      expect(sys, contains('不要连环下命令'));
    });

    test('registerOpen=true 时语域段替换禁令，红线不撤', () {
      // 禁令常开会把角色扮演功能做没；常关又把「主人不要伤害我？」放回来。
      // 开关两个方向都要钉住。
      final open = ReplyPrompt.systemPrompt(3, registerOpen: true);
      expect(open, isNot(contains('不要角色扮演式台词')));
      expect(open, contains('语域已按人设卡放开'));
      // 放开语域不是放开安全红线。
      expect(open, contains('硬性禁止（任何情况下都有效）'));
      expect(open, contains('未成年人'));
    });

    test('n=2 是两条策略不是三条', () {
      // 旧契约在 n=2 时仍要求三种策略「各一个」—— 算术上不可满足，
      // 模型只能硬凑或忽略数量。两条候选就是两条策略。
      final sys = ReplyPrompt.systemPrompt(2);
      expect(sys, contains('2 个对象'));
      expect(sys, contains('safe（稳妥承接）、forward（推进话题）'));
      expect(sys, isNot(contains('angle')));
    });

    test('n=1 固定 safe', () {
      final sys = ReplyPrompt.systemPrompt(1);
      expect(sys, contains('strategy 固定为 safe'));
    });

    test('收着档不强迫推进', () {
      // 收着档：system 的策略契约和 user 的档位块必须同一口径。旧契约
      // 在这轮仍强迫一条「forward（推进话题）」，而档位块说「不要邀约、
      // 不要加码」—— 自相矛盾的指令是怪腔的直接来源。
      final soft = ReplyPrompt.systemPrompt(3, intensity: Intensity.soft);
      expect(soft, contains('这一轮不推进'));
      expect(soft, contains('温和确认'));
      expect(soft, isNot(contains('forward（推进话题）')));

      final softTwo = ReplyPrompt.systemPrompt(2, intensity: Intensity.soft);
      expect(softTwo, contains('温和确认'));
      expect(softTwo, isNot(contains('forward（推进话题）')));

      // 默认（自然）轮的契约逐字不变。
      final natural = ReplyPrompt.systemPrompt(3);
      expect(natural, contains('forward（推进话题）、angle（换角度）'));
    });

    test('语言规则', () {
      expect(ReplyPrompt.systemPrompt(3, language: 'zh'),
          contains('回复必须使用自然中文，不要夹带英文。'));
      expect(ReplyPrompt.systemPrompt(3, language: 'en'),
          contains('回复必须使用自然英文，不要夹带中文。'));
      expect(ReplyPrompt.systemPrompt(3),
          contains('回复语言跟随对方最近一条消息'));
    });

    test('长度规则', () {
      expect(ReplyPrompt.systemPrompt(3, length: 'short'),
          contains('15 个中文字符'));
      expect(ReplyPrompt.systemPrompt(3, length: 'detailed'),
          contains('60 个中文字符'));
      expect(ReplyPrompt.systemPrompt(3), contains('40 个中文字符'));
    });
  });

  group('draftSystemPrompt', () {
    test('自由文本卡：语域禁令在场', () {
      final closed = ReplyPrompt.draftSystemPrompt(
          3, 'follow', 'standard', PersonaCard.parse('我们在暧昧期，喜欢互怼'));
      expect(closed, contains('不要角色扮演式台词'));
      expect(closed, contains('「主人」'));
    });

    test('人设卡放开语域但撤不掉红线', () {
      final open = ReplyPrompt.draftSystemPrompt(
          3, 'follow', 'standard', PersonaCard.parse('语域：亲密\n关系：主奴'));
      expect(open, isNot(contains('不要角色扮演式台词')));
      expect(open, contains('语域已按人设卡放开'));
      expect(open, contains('硬性禁止（任何情况下都有效）'));
      expect(open, contains('未成年人'));
    });
  });

  group('draftUserPrompt 分层', () {
    test('块顺序：knowledge→judgment→intensity→caution→style→relationship→convo→avoid→ask', () {
      // 顺序就是重点：判断告诉模型这是什么局，档位是对判断的解读所以紧跟
      // 其后；caution 在它后面才不会被埋掉；卡片在人设类块里最后出现，
      // 用户自己的措辞压过通用风格规则，而 system 的禁令又压过一切。
      final prompt = ReplyPrompt.draftUserPrompt(
        '朋友',
        context(notes: [addressNote]),
        30,
        tenseAnalysis,
        PersonaCard.parse('称呼：先生\n语气：克制，短句'),
        '出现了「威胁」，确认这是双方自愿、不是被推着走',
        '对方：你怎么这样',
        const ['在的'],
        3,
      );
      final at = prompt.indexOf;
      final knowledgeAt = at('以下是关于我和对方的背景与知识库');
      final judgmentAt = at('判断结果');
      final intensityAt = at('本轮推进档位');
      final cautionAt = at('需要留神的信号');
      final styleAt = at('称呼：先生');
      final relationshipAt = at('关系：朋友');
      final convoAt = at('最近对话：');
      final avoidAt = at('- 在的');
      for (final p in [knowledgeAt, judgmentAt, intensityAt, cautionAt, styleAt,
            relationshipAt, convoAt, avoidAt]) {
        expect(p, greaterThanOrEqualTo(0));
      }
      expect(knowledgeAt, lessThan(judgmentAt));
      expect(judgmentAt, lessThan(intensityAt));
      expect(intensityAt, lessThan(cautionAt));
      expect(cautionAt, lessThan(styleAt));
      expect(styleAt, lessThan(relationshipAt));
      expect(relationshipAt, lessThan(convoAt));
      expect(convoAt, lessThan(avoidAt));
      expect(prompt.endsWith('请给出 3 条候选回复。'), isTrue);
    });

    test('默认轮次提示词不变（自动档解析为自然）', () {
      // 自动档解析成「自然」时返回空串 —— 默认轮次的提示词和没有档位
      // 功能之前逐字节一致，这是向后兼容的锁。
      final card = PersonaCard.parse('');
      final bare = ReplyPrompt.draftUserPrompt(
          '朋友', context(), 30, null, card, '', '对方：在吗', const [], 2);
      final withAuto = ReplyPrompt.draftUserPrompt('朋友', context(), 30, null,
          card, '', '对方：在吗', const [], 2,
          intensity: Intensity.auto);
      expect(bare, withAuto);
      expect(ReplyPrompt.intensityBlock(Intensity.auto, null), '');
      expect(ReplyPrompt.intensityBlock(Intensity.natural, null), '');
    });

    test('avoid 列表搭车，也可以为空', () {
      final bare = ReplyPrompt.draftUserPrompt(
          '朋友', context(), 30, null, PersonaCard.parse(''), '', '对方：在吗',
          const [], 2);
      expect(bare, isNot(contains('已经给过')));

      final withAvoid = ReplyPrompt.draftUserPrompt('朋友', context(), 30, null,
          PersonaCard.parse(''), '', '对方：在吗', const ['在的', '怎么了'], 2);
      expect(withAvoid, contains('已经给过'));
      expect(withAvoid, contains('- 在的'));
      expect(withAvoid, contains('- 怎么了'));
      expect(withAvoid.indexOf('- 在的'), lessThan(withAvoid.indexOf('- 怎么了')));
    });
  });

  group('draftUserPrompt 的关系行', () {
    test('联系人自己的关系压过全局默认，且只出现一次', () {
      // 联系人写了自己的关系时，背景块已经带了它；正文行不得再把全局关系
      // 重复一遍 —— 两行「关系：」打架时模型两头都想贴，写出来的既不像
      // 客户服务也不像伴侣。
      final ctx = context(
        contact: const Contact(id: 'c1', name: '王总', relationship: '销售和客户'),
      );
      final prompt = ReplyPrompt.draftUserPrompt(
          '对方是我的伴侣', ctx, 30, null, PersonaCard.parse(null), '',
          '对方：在吗', const [], 3);
      expect(prompt, contains('关系：销售和客户'));
      expect(prompt, isNot(contains('伴侣')));
      expect('关系：'.allMatches(prompt).length, 1);
    });

    test('没有联系人时全局关系恰好出现一次', () {
      final prompt = ReplyPrompt.draftUserPrompt('朋友', null, 30, null,
          PersonaCard.parse(null), '', '对方：在吗', const [], 3);
      expect(prompt, contains('关系：朋友'));
      expect('关系：'.allMatches(prompt).length, 1);
    });
  });

  group('judgmentWords', () {
    test('判断结果给技能匹配的是人话关键词', () {
      // 技能匹配只看聊天原文时，方法论要等到冲突说出口才撞上关键词；
      // 判断层早已看出局势偏紧，这里把它翻成人话喂给检索。
      const a = Analysis(
        trueIntent: Choice(choice: 'vent_anger', confidence: 0.9),
        dangerLevel: Score(score: 6.0, confidence: 0.9, maxLevel: 9),
        sheNeeds: Choice(choice: 'care', confidence: 0.7),
        bestAction: Choice(choice: 'acknowledge', confidence: 0.7),
        latencyMs: 0,
      );
      expect(ReplyPrompt.judgmentWords(a),
          '在发泄情绪 被在乎、被安慰 先承认对方的感受 局势紧张 冲突');
    });

    test('局势不紧时不喊冲突，免得每轮都往方法论上撞', () {
      const a = Analysis(
        trueIntent: Choice(choice: 'vent_anger', confidence: 0.9),
        dangerLevel: Score(score: 1.0, confidence: 0.9, maxLevel: 9),
        sheNeeds: Choice(choice: 'care', confidence: 0.7),
        bestAction: Choice(choice: 'acknowledge', confidence: 0.7),
        latencyMs: 0,
      );
      expect(ReplyPrompt.judgmentWords(a),
          '在发泄情绪 被在乎、被安慰 先承认对方的感受');
    });

    test('空判断返回空串', () {
      expect(ReplyPrompt.judgmentWords(null), '');
    });
  });

  group('场景注入', () {
    final support = Scenarios.byId('support_agent');

    setUpAll(() {
      expect(support, isNotNull);
    });

    test('内置场景按蛇形 id 查找', () {
      expect(Scenarios.chatCopilot.id, 'chat_copilot');
      expect(Scenarios.byId('chat_copilot'), isNotNull);
      expect(Scenarios.byId('support_agent'), isNotNull);
      expect(Scenarios.byId('language_learning'), isNotNull);
      expect(Scenarios.byId('live_interaction'), isNotNull);
      expect(Scenarios.byId('social_a11y'), isNotNull);
      expect(Scenarios.byId('nope'), isNull);
    });

    test('chat_copilot 的附加段是空串', () {
      expect(Scenarios.chatCopilot.systemAddendum, '');
      expect(Scenarios.chatCopilot.userAddendum, '');
    });

    test('chat_copilot 时 systemPrompt 与无场景参数逐字节一致', () {
      expect(ReplyPrompt.systemPrompt(3, scenario: Scenarios.chatCopilot),
          ReplyPrompt.systemPrompt(3));
      expect(
          ReplyPrompt.systemPrompt(3, scenario: Scenarios.byId('chat_copilot')),
          ReplyPrompt.systemPrompt(3));
    });

    test('chat_copilot 时 draftSystemPrompt 与无场景参数逐字节一致', () {
      final card = PersonaCard.parse('称呼：先生');
      expect(
        ReplyPrompt.draftSystemPrompt(3, 'follow', 'standard', card,
            scenario: Scenarios.chatCopilot),
        ReplyPrompt.draftSystemPrompt(3, 'follow', 'standard', card),
      );
    });

    test('chat_copilot 时 draftUserPrompt 与无场景参数逐字节一致', () {
      final plain = ReplyPrompt.draftUserPrompt('朋友', null, 30, null,
          PersonaCard.parse(''), '', '对方：在吗', const [], 3);
      final copilot = ReplyPrompt.draftUserPrompt('朋友', null, 30, null,
          PersonaCard.parse(''), '', '对方：在吗', const [], 3,
          scenario: Scenarios.chatCopilot);
      expect(copilot, plain);
    });

    test('非默认场景把 systemAddendum 追加在 systemPrompt 末尾', () {
      final s = support!;
      expect(s.systemAddendum, isNotEmpty);
      final plain = ReplyPrompt.systemPrompt(3);
      final withScenario = ReplyPrompt.systemPrompt(3, scenario: s);
      expect(withScenario.startsWith(plain), isTrue);
      expect(withScenario.endsWith(s.systemAddendum), isTrue);
    });

    test('非默认场景把 userAddendum 插在最后的候选条数一行之前', () {
      final s = support!;
      expect(s.userAddendum, isNotEmpty);
      const ask = '请给出 3 条候选回复。';
      final plain = ReplyPrompt.draftUserPrompt('朋友', null, 30, null,
          PersonaCard.parse(''), '', '对方：在吗', const [], 3);
      final withScenario = ReplyPrompt.draftUserPrompt('朋友', null, 30, null,
          PersonaCard.parse(''), '', '对方：在吗', const [], 3,
          scenario: s);
      final head = plain.substring(0, plain.lastIndexOf(ask));
      expect(withScenario.startsWith(head), isTrue);
      expect(withScenario.endsWith(ask), isTrue);
      final addendumAt = withScenario.indexOf(s.userAddendum);
      expect(addendumAt, greaterThanOrEqualTo(0));
      expect(addendumAt, lessThan(withScenario.lastIndexOf(ask)));
    });
  });

  group('G7 偏好附言（preference_addendum 笔记，写手专用通道）', () {
    const addendum = '用户对历史候选的反馈统计：回复偏正式（3 次）——应更口语';

    Note preferenceNote() => const Note(
          id: 'preference_addendum',
          title: '用户的风格偏好反馈',
          content: addendum,
          type: noteTypePreferenceAddendum,
        );

    test('knowledgeBlock 渲染偏好附言（只带附言的 ctx 不再整段丢弃）', () {
      final out = ReplyPrompt.knowledgeBlock(
          '朋友', context(notes: [preferenceNote()]), 30);

      expect(out, contains(addendum));
      expect(out, contains('结构化反馈'));
    });

    test('background() 跳过偏好附言笔记：判断路的 state 看不到它', () {
      final background =
          context(notes: [preferenceNote()]).background('朋友');

      expect(background, isEmpty);
      // 对照：普通知识笔记照常进 background（判断路看得到），附言不混进去。
      final normal = context(notes: [
        const Note(id: 'n1', title: '备忘', content: '普通知识笔记'),
        preferenceNote(),
      ]).background('朋友');
      expect(normal, contains('普通知识笔记'));
      expect(normal, isNot(contains('回复偏正式')));
    });

    test('无偏好附言时 knowledgeBlock 不出现偏好段（与接入前同形）', () {
      final out = ReplyPrompt.knowledgeBlock(
          '朋友',
          context(
            history: const [LogEntry(side: 'other', text: '在吗')],
          ),
          30);
      expect(out, isNot(contains('结构化反馈')));
      // 只有风格样本也不触发偏好段——两种写手专用通道互不串味。
      final withStyle = ReplyPrompt.knowledgeBlock(
          '朋友',
          context(
            history: const [LogEntry(side: 'other', text: '在吗')],
            notes: const [
              Note(
                  id: 's1',
                  title: '样本',
                  content: '我今天顺路把票取了。',
                  type: noteTypeStyleSample),
            ],
          ),
          30);
      expect(withStyle, isNot(contains('结构化反馈')));
    });
  });
}
