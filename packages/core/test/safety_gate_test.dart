import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 安全闸门 —— 对照旧仓库 `core/safety/SafetyGateTest.kt` 的思路逐条钉住。
///
/// 闸门是这个应用里唯一「主动拒绝帮忙」的地方，所以测试一半在测它拦什么，
/// 一半在测它**放过**什么。两种失败都真实发生过：太松，就会替本该拒绝的
/// 对话出候选；太急，一句聊游戏时随口的「未成年不让玩」就会让整轮没有候选，
/// 用户分不清是网络坏了还是助手在拒绝。
void main() {
  // 通用测试卡：关系/语域/两条硬边界。硬边界展开后含裸词「家人」「留痕」。
  final card = PersonaCard.parse('关系：主奴\n语域：亲密\n硬边界：不要提家人、不要留痕');

  group('放行', () {
    test('普通聊天干净放行，不带一个字的谨慎提示', () {
      final v = SafetyGate.check(const ['晚上一起吃饭吗', '那家店我订好了'], card);
      expect(v.blocked, isFalse);
      expect(v.caution, '');
    });

    test('空输入放行：没有对方的话就没有可检查的东西', () {
      final empty = SafetyGate.check(const [], card);
      expect(empty.blocked, isFalse);
      expect(empty.caution, '');
      // 空白行被过滤掉之后等于空输入（采集层可能带来未填满的窗口）。
      final blank = SafetyGate.check(const ['   ', ''], card);
      expect(blank.blocked, isFalse);
      expect(blank.caution, '');
    });

    test('含亲密暗示但不涉未成年与边界的对话照常放行', () {
      // 闸门拦的是硬伤，不是语气：这句在一场双方约定的角色场景里是正常台词。
      final v = SafetyGate.check(const ['过来，今晚照上次说的来'], card);
      expect(v.blocked, isFalse);
      expect(v.caution, '');
    });

    test('用户没写边界时不替用户发明边界', () {
      // 自由文本不扫描：助手在用户没写任何底线时必须照常帮忙，
      // 否则一句「你家人知道吗」就把正常聊天掐死了。
      final free = PersonaCard.parse('我们在暧昧期，喜欢互怼');
      expect(
        SafetyGate.check(const ['你家人知道我们这样吗'], free).blocked,
        isFalse,
      );
      expect(
        SafetyGate.check(const ['你家人知道我们这样吗'], null).blocked,
        isFalse,
      );
    });
  });

  group('阻断', () {
    test('违法词单独出现就拦截', () {
      const lines = ['我们下药吧', '你敢不敢偷拍', '不给钱就勒索你', '我被人强奸过'];
      for (final line in lines) {
        expect(SafetyGate.check([line], card).blocked, isTrue, reason: line);
      }
    });

    test('自伤词拦截而不是起草，提醒先确认人是否安全', () {
      final v = SafetyGate.check(const ['我真的想去跳楼'], card);
      expect(v.blocked, isTrue);
      expect(v.blockReason, contains('安全'));
    });

    test('约定的安全词当场拦停整轮', () {
      // 安全词是两个人之间的约定，不是启发式：一旦说出，这场就结束了。
      // 离线实测里模型通常自己会停——但「通常」不是契约，滑过安全词的
      // 候选是唯一没有回头路的一种失败。
      final agreed = PersonaCard.parse('关系：主奴\n语域：亲密\n硬边界：不要留痕\n安全词：红灯');
      final v = SafetyGate.check(const ['红灯。先停一下'], agreed);
      expect(v.blocked, isTrue);
      expect(v.blockReason, contains('安全词'));
      // 卡上没写安全词，「红灯」就只是个词。
      expect(SafetyGate.check(const ['红灯。先停一下'], card).blocked, isFalse);
      // 单说一个词也拦：红灯仍然归红灯。
      expect(SafetyGate.check(const ['红灯'], agreed).blocked, isTrue);
    });

    test('安全词按分隔符切开并做空白扁平化', () {
      // 卡上的实际写法是「红灯/黄灯」「红灯、黄灯」这类分隔符列表；
      // 行内混入空格或全半角差异也不能藏住词。flatten 对**两边**都做：
      // 词与消息各自去掉空白再比对。
      final multi = PersonaCard.parse('安全词：红灯、停下/STOP');
      expect(SafetyGate.safeWords(multi), ['红灯', '停下', 'stop']);

      final spaced = PersonaCard.parse('安全词：red light');
      // 消息里的大小写与空格被扁平化：RED LIGHT → redlight，命中词 redlight。
      final v = SafetyGate.check(const ['RED LIGHT now'], spaced);
      expect(v.blocked, isTrue);
      expect(v.blockReason, contains('安全词'));
    });

    test('未成年信号×亲密内容组合必须拒绝', () {
      final v = SafetyGate.check(const ['我才15岁，你想怎么调教我'], card);
      expect(v.blocked, isTrue);
      expect(v.blockReason, contains('未成年'));
    });

    test('写明的周岁数同样拦在起草之前', () {
      // 年龄只和亲密内容组合时才拦，所以用例里必须带上亲密的那一半。
      const lines = ['我17岁', '我今年 16 周岁', '人家9岁啦'];
      for (final line in lines) {
        final v = SafetyGate.check(['$line，想跟你文爱'], card);
        expect(v.blocked, isTrue, reason: line);
      }
      // 18 及以上完全不算未成年信号。
      expect(SafetyGate.check(const ['我18岁，想跟你文爱'], card).blocked, isFalse);
      expect(SafetyGate.check(const ['我28岁'], card).blocked, isFalse);
    });

    test('写下的硬边界逐字拦停整轮', () {
      // 卡写的是「不要提家人」，展开后有裸词「家人」；匹配是逐字的，
      // 所以消息里必须真出现用户写的那个词。
      final v = SafetyGate.check(const ['你家人知道我们这样吗'], card);
      expect(v.blocked, isTrue);
      expect(v.blockReason, contains('家人'));
      expect(v.blockReason, contains('硬边界'));

      // 同义词不算——逐字匹配下「你妈」不是「家人」。这是刻意的能力边界
      // （设置页提示用户写词本身），也是它只在写下来时才生效的原因。
      expect(SafetyGate.check(const ['你妈知道我们这样吗'], card).blocked, isFalse);
    });

    test('每一条边界都会被检查，不止第一条', () {
      final multi = PersonaCard.parse('硬边界：不要提家人、不要留痕、不要提分手');
      // 「不要提分手」展开出裸词「分手」，与「提分手」都能命中。
      expect(SafetyGate.check(const ['要不我们分手吧'], multi).blocked, isTrue);
      expect(SafetyGate.check(const ['记得删记录，别留痕'], multi).blocked, isTrue);
      expect(SafetyGate.check(const ['我到家了'], multi).blockReason, isNull);
    });
  });

  group('谨慎', () {
    test('单独的未成年信号只是谨慎提示，不是拒绝', () {
      // 「未成年」会出现在日常聊天里。只看词就拦，助手会拒绝一场正常对话。
      final v = SafetyGate.check(const ['那个游戏未成年不让玩'], card);
      expect(v.blocked, isFalse);
      expect(v.caution, contains('未成年人'));
    });

    test('自愿含糊成为提示词里的谨慎行', () {
      final v = SafetyGate.check(const ['你今天必须听我的，别逼我生气'], card);
      expect(v.blocked, isFalse);
      expect(v.caution, contains('自愿'));
    });

    test('约定的黄灯只减速不拦停，红灯照样拦', () {
      // 黄灯是双方约定里的减速信号：要提醒起草先确认状态、降低强度，但不能像
      // 红灯那样把整轮拦掉——实测里对方说「黄灯哦」之后场景继续，这正是黄灯
      // 的本意；旧的「安全词：红灯停、黄灯缓」写法会把黄灯塞进安全词里硬拦。
      final agreed = PersonaCard.parse('关系：主奴\n语域：亲密\n安全词：红灯\n黄灯：黄灯');
      final v = SafetyGate.check(const ['黄灯哦～'], agreed);
      expect(v.blocked, isFalse);
      expect(v.caution, contains('黄灯信号'));
      expect(v.caution, contains('减速'));
      // 黄灯是 caution 不是 block：不带「我不给候选」这类拦截话术。
      expect(v.caution, isNot(contains('不给候选')));
      // 卡上没写黄灯，「黄灯」两个字只是个词。
      final bare = PersonaCard.parse('关系：主奴\n语域：亲密\n安全词：红灯');
      expect(SafetyGate.check(const ['黄灯哦～'], bare).caution, '');
      // 红灯仍然拦整轮，黄灯信号不能稀释它。
      expect(SafetyGate.check(const ['红灯'], agreed).blocked, isTrue);
    });

    test('黄灯的谨慎行排在最前', () {
      // caution 列表第一位是黄灯——它比地点/换说法提醒更优先，
      // 因为那是双方明说过的约定，其余只是启发式。
      // 这条消息同时踩中黄灯、换说法边界（录）与公共地点（楼道）。
      final agreed =
          PersonaCard.parse('关系：主奴\n语域：亲密\n硬边界：不要留痕、不要在外面露出\n安全词：红灯\n黄灯：黄灯');
      final v = SafetyGate.check(const ['黄灯哦，我在楼道，想把你刚说的那些录下来'], agreed);
      expect(v.blocked, isFalse);
      expect(v.caution, startsWith('对方打出了你们约好的黄灯信号'));
      // 三个提醒都在，一个不少。
      expect(v.caution, contains('换了个说法'));
      expect(v.caution, contains('先确认环境'));
    });

    test('换说法碰到硬边界时提示进提示词，而不是整轮拦掉', () {
      // 「不要留痕」只匹配词本身，所以「录下来我自己留着」曾经滑过去——
      // 真实运行里三条候选全部答应了。这是 caution 而非拒绝，关键是把
      // 「只能拒绝或停下确认」的指令送进提示词。
      final v = SafetyGate.check(const ['我想把你刚说的那些录下来，就我自己留着'], card);
      expect(v.blocked, isFalse);
      expect(v.caution, contains('硬边界'));
      expect(v.caution, contains('留痕'));
      expect(v.caution, contains('不要答应'));

      // 同一族的其他说法（拍）也够得着：边界写「不要拍照」，命中词「拍」。
      final photo = PersonaCard.parse('硬边界：不要拍照');
      final shot = SafetyGate.check(const ['抬头，我帮你拍一张'], photo);
      expect(shot.blocked, isFalse);
      expect(shot.caution, contains('换了个说法'));
    });

    test('公共地点只在卡声明了相关边界时才是谨慎', () {
      // 卡里写了「不要在外面露出」：楼道就是值得提醒的环境。
      final careful = PersonaCard.parse('关系：主奴\n硬边界：不要在外面露出');
      final v = SafetyGate.check(const ['我在楼道里，室友在屋里'], careful);
      expect(v.blocked, isFalse);
      expect(v.caution, contains('先确认环境'));
      // 没写这类边界时，提到地点就只是提到地点：见句「我在路上」就提醒，
      // 只会让用户学会无视这一行。
      expect(SafetyGate.check(const ['我在楼道里，室友在屋里'], card).caution, '');
    });
  });
}
