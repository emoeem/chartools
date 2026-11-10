import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 人设卡解析锁 —— 对照旧仓库 `core/kb/PersonaCardTest.kt`。
///
/// 人设卡有两个互相拉扯的职责：用户写了结构就带结构，没写结构就**逐字原样**。
/// 「逐字原样」是承重的一半：卡功能之前写的每一条联系人备注都是自由文本，
/// 必须原封不动进提示词 —— 一个冒号就能把备注变成卡的话，老用户的措辞就
/// 被悄悄改掉了。另一头是硬边界/避谈/安全词/黄灯四件事绝不能混：闸门拦
/// 「对方」的话，避谈只管「我方」措辞，黄灯是减速不是停止。
void main() {
  group('自由文本不变形', () {
    test('自由文本逐字返回', () {
      const note = '我们在暧昧期，喜欢互怼';
      final card = PersonaCard.parse(note);
      expect(card.structured, isFalse);
      expect(card.registerOpen, isFalse);
      expect(card.promptText(), note);
    });

    test('有冒号但没有认得的键仍是自由文本', () {
      // 冒号不是卡，认得的键才是卡。这样的备注不许被重新排版，
      // 否则提示词无缘无故就变了。
      const note = '我们：暧昧期，喜欢互怼';
      final card = PersonaCard.parse(note);
      expect(card.structured, isFalse);
      expect(card.promptText(), note);
    });

    test('空白输入不炸', () {
      expect(PersonaCard.parse(null).hasContent(), isFalse);
      expect(PersonaCard.parse('   \n  ').hasContent(), isFalse);
      expect(PersonaCard.parse(null).promptText(), '');
    });

    test('只贴示例行不足以变成卡', () {
      // 只认出「示例行」不算结构化：碰巧带「我：…」的自由文本不许悄悄变形。
      const note = '我：今天想你了';
      final card = PersonaCard.parse(note);
      expect(card.structured, isFalse);
      expect(card.promptText(), note);
    });
  });

  group('键值卡', () {
    test('一张卡带全所有字段', () {
      final card = PersonaCard.parse(
          '称呼：先生\n'
          '关系：主奴\n'
          '语气：克制，短句，不解释\n'
          '情境：书房，晚上\n'
          '硬边界：不要提家人、不要留痕\n'
          '安全词：红灯\n'
          '示例：\n'
          '我：今天想你了\n'
          '对方：嗯，等着\n');
      expect(card.structured, isTrue);
      expect(card.address, '先生');
      expect(card.relation, '主奴');
      expect(card.tone, '克制，短句，不解释');
      expect(card.scene, '书房，晚上');
      expect(card.safeword, '红灯');
      // 原话保留，同时展开出闸门要匹配的关键词 —— 只写「不要提家人」
      // 永远匹配不到对方真实发来的消息。
      expect(card.boundaries, contains('不要提家人'));
      expect(card.boundaries, contains('提家人'));
      expect(card.boundaries, contains('家人'));
      expect(card.boundaries, contains('不要留痕'));
      expect(card.examples, ['我：今天想你了', '对方：嗯，等着']);

      final prompt = card.promptText();
      expect(prompt, startsWith('<persona_card>'));
      expect(prompt, endsWith('</persona_card>'));
      expect(prompt, contains('称呼：先生'));
      expect(prompt, contains('硬边界（这些内容绝不可以出现在回复里）：'));
      expect(prompt, contains('不要提家人'));
      expect(prompt, contains('不要留痕'));
      // 「示例：」只是下面几行的引导头，不是值 —— 不许当作「补充」指令
      // 被模型读回去。
      expect(prompt, isNot(contains('补充：示例')));
      expect(prompt, contains('我：今天想你了'));
      // 示例是风格样本不是对话：模型不许把「今天想你了」当成刚说过的话来答。
      expect(prompt, contains('只学语气和称呼，不是当前对话内容'));
    });

    test('键别名中英都认', () {
      final en = PersonaCard.parse(
          'address: sir\nrelation: partner\ntopic: domain\nmode: bdsm\nsafeword: red');
      expect(en.address, 'sir');
      expect(en.relation, 'partner');
      expect(en.topic, 'domain');
      expect(en.registerOpen, isTrue); // bdsm 在放开词表里
      expect(en.safeword, 'red');

      final cn = PersonaCard.parse('称谓：女士\n身份：上司\n口吻：克制\n场景：办公室');
      expect(cn.address, '女士');
      expect(cn.relation, '上司');
      expect(cn.tone, '克制');
      expect(cn.scene, '办公室');
    });

    test('英文键与 Card V2 示例行都接受', () {
      final card = PersonaCard.parse(
          'address: sir\n'
          'tone: clipped\n'
          '語域: roleplay\n'
          '示例:\n'
          '我：late again\n'
          '对方：I noticed\n');
      // 「語域」是繁体 —— 不是这个应用声明认识的键，这张卡按它实际
      // 写了什么来判。
      expect(card.structured, isTrue);
      expect(card.address, 'sir');
      expect(card.tone, 'clipped');
      expect(card.registerOpen, isFalse);
      expect(card.examples, ['我：late again', '对方：I noticed']);
    });

    test('示例行前缀：我/对方/他/她/{{user}}/{{char}} 都接', () {
      final card = PersonaCard.parse(
          '语气：短句\n'
          '我：今天想你了\n'
          '我:late again\n'
          '对方：嗯，等着\n'
          '他：来了\n'
          '她：在路上\n'
          '{{user}}: hi\n'
          '{{char}}: hey\n');
      expect(
        card.examples,
        [
          '我：今天想你了',
          '我:late again',
          '对方：嗯，等着',
          '他：来了',
          '她：在路上',
          '{{user}}: hi',
          '{{char}}: hey',
        ],
      );
    });

    test('语域开关：不开/关闭=false；亲密/文爱=true；开/on/true=true', () {
      // 自由文本里出现「亲密」不放开：否则一条普通的风格备注就把默认禁掉的
      // 「主人」语域重新打开了。
      expect(PersonaCard.parse('关系很亲密，随便聊').registerOpen, isFalse);

      // 中文「不开」里含有会被当成 yes 的「开」，所以否定词先查。
      expect(PersonaCard.parse('语域：不开').registerOpen, isFalse);
      expect(PersonaCard.parse('语域：关闭').registerOpen, isFalse);
      expect(PersonaCard.parse('register: off').registerOpen, isFalse);
      expect(PersonaCard.parse('语域：默认').registerOpen, isFalse);

      expect(PersonaCard.parse('语域：亲密').registerOpen, isTrue);
      expect(PersonaCard.parse('语域：文爱').registerOpen, isTrue);
      expect(PersonaCard.parse('register: roleplay').registerOpen, isTrue);
      expect(PersonaCard.parse('mode: intimate').registerOpen, isTrue);
      expect(PersonaCard.parse('语域：开').registerOpen, isTrue);
      expect(PersonaCard.parse('register: on').registerOpen, isTrue);
      expect(PersonaCard.parse('语域：true').registerOpen, isTrue);
    });

    test('边界短语同时展开出闸门要匹配的关键词', () {
      // 用户把限制写成指令（「不要叫我主人」），闸门要匹配的却是对方
      // 实际发来的裸词。「不」放在替换表最后是有意的：先试它会把
      // 「不要提家人」削成「要提家人」。
      final card = PersonaCard.parse('硬边界：不要叫我主人，不要提分手，不提家人');
      expect(card.boundaries, contains('不要叫我主人'));
      expect(card.boundaries, contains('主人'));
      expect(card.boundaries, contains('分手'));
      expect(card.boundaries, contains('家人'));
    });

    test('认不出的行进补充而不是被丢掉', () {
      final card = PersonaCard.parse('关系：同事\n她最近在赶一个大项目，别催她');
      expect(card.structured, isTrue);
      expect(card.relation, '同事');
      expect(card.extra, contains('她最近在赶一个大项目，别催她'));
      expect(card.promptText(), contains('她最近在赶一个大项目，别催她'));
    });

    test('链接地址不会被当成键', () {
      final card = PersonaCard.parse('语气：随便\n头像链接 http://example.com/a.png');
      expect(card.structured, isTrue);
      expect(card.tone, '随便');
      expect(card.extra.any((e) => e.contains('http://example.com')), isTrue);
    });
  });

  group('主题键', () {
    test('主题把回复钉在领域上', () {
      final card = PersonaCard.parse('主题：网调');
      expect(card.structured, isTrue);
      expect(card.topic, '网调');
      expect(card.promptText(), contains('主题：网调'));
      expect(card.promptText(), contains('这段对话整体就在这个领域里'));
    });
  });

  group('黄灯键', () {
    test('黄灯是独立的键，不是塞进安全词里硬拦', () {
      // 2026-10-07 实测聊天记录里对方真实使用了「黄灯哦」；旧的
      // 「安全词：红灯停、黄灯缓」写法会把黄灯塞进安全词里一起硬拦。
      // 黄灯的语义是减速确认，必须是独立的键。
      final card = PersonaCard.parse('关系：主奴\n语域：亲密\n安全词：红灯\n黄灯：黄灯');
      expect(card.structured, isTrue);
      expect(card.safeword, '红灯');
      expect(card.yellow, '黄灯');
      final prompt = card.promptText();
      expect(prompt, contains('黄灯：黄灯'));
      expect(prompt, contains('减速确认'));
      // 没写黄灯的卡不得凭空多出黄灯段。
      final bare = PersonaCard.parse('关系：主奴\n安全词：红灯');
      expect(bare.promptText(), isNot(contains('黄灯：')));
    });
  });

  group('避谈键', () {
    test('避谈是独立字段，绝不进硬边界闸门', () {
      // 硬边界逐字拦**对方**的消息（SafetyGate），避谈只约束**我方**措辞。
      // 混在一个键里时，销售的「稳赚」会被当成硬边界去拦客户的问题 ——
      // 恰好在最需要回复的一轮把候选掐掉。
      final card = PersonaCard.parse('关系：销售和客户\n避谈：稳赚、保证收益');
      expect(card.structured, isTrue);
      expect(card.avoid, contains('稳赚'));
      expect(card.avoid, contains('保证收益'));
      expect(card.boundaries, isEmpty);
      final prompt = card.promptText();
      expect(prompt, contains('避谈'));
      expect(prompt, contains('不许换种说法向对方许诺'));
      // 避谈里的词对方说了不拦轮：这是它与硬边界的本质区别。
      expect(
        SafetyGate.check(const ['这个能稳赚吗？保证收益吗'], card).blocked,
        isFalse,
      );
      // 只写避谈一行也算结构化卡（键认出来了）。
      expect(PersonaCard.parse('避谈：稳赚').structured, isTrue);
    });
  });
}
