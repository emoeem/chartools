// G8 确认入库的 persona 追加约束（kimi-review 第 3 轮 #7，fix(#9 K-5)）：
// 同文本不重复追加；persona 最多保留最近 30 行、超限淘汰最旧。contact_store
// 是 app 层实现，core 测不了它，此前整类零测试——这里钉住新约束，顺带钉住
// 被本次改写路过的既有契约（首次追加、目标解析落空保留候选、落盘形状）。
//
// fake 注入：ContactStore 只依赖 shared_preferences，单测里用
// SharedPreferences.setMockInitialValues 提供内存存档（与
// settings_store_test.dart 同一口径），不需要平台通道。
import 'dart:convert';

import 'package:chartools_app/application/contact_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 建一个带一名激活联系人的 store（联系人人设初始为 [persona]）。
  Future<ContactStore> newStore({String persona = ''}) async {
    SharedPreferences.setMockInitialValues({});
    final store = ContactStore();
    await store.load();
    final contact = await store.create(displayName: '小测', persona: persona);
    store.setActive(contact.id);
    return store;
  }

  /// 暂存一条文本并确认，返回确认后目标联系人的 persona。
  Future<String> confirm(ContactStore store, String text) async {
    store.stageCandidateFact(text);
    final fact = store.stagedFacts.value.last;
    final updated = await store.confirmStagedFact(fact);
    return updated!.persona;
  }

  test('确认事实追加进 persona 并移出暂存区（既有契约不受改写影响）', () async {
    final store = await newStore();
    final id = store.activeContact.value!.id;

    final persona = await confirm(store, '她是研究生');

    // 首次追加：persona 从空串变成这一行，没有前导空行。
    expect(persona, '她是研究生');
    expect(store.byId(id)!.persona, '她是研究生');
    // 候选已移出暂存区。
    expect(store.stagedFacts.value, isEmpty);
    // 已落盘：存档 JSON 里搜得到这条事实。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('contacts')!, contains('她是研究生'));
  });

  test('fix(#9 K-5) 去重：同文本不重复追加、不落盘、updatedAt 不刷新', () async {
    final store = await newStore();
    final id = store.activeContact.value!.id;

    await confirm(store, '她是研究生');
    final before = store.byId(id)!;

    // 同一条事实再次确认（模拟重复暂存 + 连点确认）：不追加第二份。
    store.stageCandidateFact('她是研究生');
    final again = await store.confirmStagedFact(store.stagedFacts.value.last);

    expect(again, isNotNull); // 非 null = 确认成功，capture_page 才会提示。
    final after = store.byId(id)!;
    expect(after.persona.split('她是研究生').length - 1, 1);
    expect(after.persona.split('\n'), hasLength(1));
    // 没有任何变化值得写：updatedAt 不刷新、identical 不换新实例。
    expect(after.updatedAt, before.updatedAt);
    expect(identical(after, before), isTrue);
    // 候选照常移出暂存区，不会留在卡上等下次确认。
    expect(store.stagedFacts.value, isEmpty);
    // 盘上也没有新写入（mock 存档即写入目标）。
    final prefs = await SharedPreferences.getInstance();
    final saved =
        (jsonDecode(prefs.getString('contacts')!) as Map<String, dynamic>)['contacts']
            as List<dynamic>;
    expect(saved, hasLength(1));
    expect((saved.single as Map<String, dynamic>)['persona'], '她是研究生');
  });

  test('fix(#9 K-5) 去重按 trim 后比较：只差首尾空白的同文本也判重', () async {
    final store = await newStore();

    await confirm(store, '他们在合作做毕设');
    // stageCandidateFact 入口已经 trim 过，这里手工构造带空白的候选，
    // 才真正落到 confirmStagedFact 侧的逐行 trim 比较。
    final fact = StagedCandidateFact(
      seq: 99,
      text: ' 他们在合作做毕设 ',
      contactId: store.activeContact.value!.id,
      stagedAt: 0,
    );
    final updated = await store.confirmStagedFact(fact);

    expect(updated, isNotNull);
    expect(store.activeContact.value!.persona.split('\n'), hasLength(1));
    expect(store.activeContact.value!.persona, '他们在合作做毕设');
    // 手工构造的候选同样照常移出暂存区。
    expect(store.stagedFacts.value, isEmpty);
  });

  test('fix(#9 K-5) 候选 trim 后为空：不追加空行，候选照常移出暂存区', () async {
    final store = await newStore();

    // stageCandidateFact 自己会拒空文本，这个入口只能靠手工构造触达。
    const blank = StagedCandidateFact(seq: 1, text: '  ', stagedAt: 0);
    final updated = await store.confirmStagedFact(blank);

    expect(updated, isNotNull);
    expect(store.activeContact.value!.persona, isEmpty);
    expect(store.stagedFacts.value, isEmpty);
  });

  test('fix(#9 K-5) 上限：第 31 条确认后淘汰最旧一条，保留最近 30 行', () async {
    final store = await newStore();

    for (var i = 1; i <= 31; i++) {
      await confirm(store, '事实${i.toString().padLeft(2, '0')}');
    }

    final persona = store.activeContact.value!.persona;
    final lines = persona.split('\n');
    expect(lines, hasLength(30));
    expect(lines.first, '事实02'); // 最旧的「事实01」被淘汰。
    expect(lines.last, '事实31');
    expect(persona.contains('事实01'), isFalse);
  });

  test('fix(#9 K-5) 上限边界：恰好 30 条不淘汰', () async {
    final store = await newStore();

    for (var i = 1; i <= 30; i++) {
      await confirm(store, '事实${i.toString().padLeft(2, '0')}');
    }

    final lines = store.activeContact.value!.persona.split('\n');
    expect(lines, hasLength(30));
    expect(lines.first, '事实01');
    expect(lines.last, '事实30');
  });

  test('fix(#9 K-5) 上限按 persona 全部行计数：手写正文与事实共用一份预算', () async {
    // 这是行级上限的既定取舍：persona 没有行级来源标记，手写多行正文与
    // 确认事实一起计入 30 行，超限同样从最旧一行开始淘汰——测试钉住这个
    // 语义，避免将来无意识改成「只对手写行宽容/只对事实宽容」的两种口径。
    final handwritten =
        List.generate(29, (i) => '手写${(i + 1).toString().padLeft(2, '0')}');
    final store = await newStore(persona: handwritten.join('\n'));

    await confirm(store, '事实A');
    await confirm(store, '事实B');

    final lines = store.activeContact.value!.persona.split('\n');
    expect(lines, hasLength(30)); // 29 + 2 = 31 → 淘汰最旧一行（手写01）。
    expect(lines.first, '手写02');
    expect(lines[27], '手写29');
    expect(lines[28], '事实A');
    expect(lines.last, '事实B');
  });

  test('目标解析落空：返回 null、候选保留在暂存区（既有契约不受改写影响）', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ContactStore();
    await store.load(); // 没有任何联系人，也没有激活。

    store.stageCandidateFact('她是研究生');
    final fact = store.stagedFacts.value.single;
    final updated = await store.confirmStagedFact(fact);

    expect(updated, isNull);
    expect(store.stagedFacts.value, [fact]); // 候选留下，等用户先选联系人。
  });
}
