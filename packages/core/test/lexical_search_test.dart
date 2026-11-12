import 'package:chartools_core/src/persona_kb/lexical_search.dart';
import 'package:test/test.dart';

/// LexicalSearch（BM25 超越版）测试。钉五件事：
///
///  1. 单字 + 二元组粗分词（顺序、拉丁段、单字查询）；
///  2. BM25 打分排序正确性（长度归一化、tf、k 截断、minScore、零命中不出场）；
///  3. per-term 得分分解（分项和 = 总分、贡献降序、idf 稀有词更高）；
///  4. tags / type 过滤；
///  5. 评测钩子：relevantIds → precision@k / recall@k / 逐命中相关性。
///
/// 测试直接 import `src/` 路径：barrel（chartools_core.dart）另有归属人，
/// 挂载导出由集成方统一处理。
void main() {
  LexDoc doc(String id, String text,
          {List<String> tags = const [], String type = ''}) =>
      LexDoc(id: id, text: text, tags: tags, type: type);

  group('tokenize：单字 + 二元组粗分词', () {
    test('纯 Han：单字 + 重叠二元组，顺序稳定', () {
      // 输出顺序：单字后紧跟它与前一字组成的二元组
      expect(LexicalSearch.tokenize('知识库'), ['知', '识', '知识', '库', '识库']);
      expect(
        LexicalSearch.tokenize('你好，世界'),
        ['你', '好', '你好', '世', '界', '世界'],
      );
    });

    test('拉丁/数字连续段一枚小写 token', () {
      expect(LexicalSearch.tokenize('Hello世界'), ['hello', '世', '界', '世界']);
      expect(LexicalSearch.tokenize('a1b'), ['a1b']);
      expect(LexicalSearch.tokenize('做SP的'), ['做', 'sp', '的']);
    });

    test('单字查询可成词（超越 legacy 的二元组-only）', () {
      expect(LexicalSearch.tokenize('机'), ['机']);
    });

    test('空串与纯标点', () {
      expect(LexicalSearch.tokenize(''), isEmpty);
      expect(LexicalSearch.tokenize('，。！？'), isEmpty);
    });
  });

  group('BM25 排序正确性', () {
    test('同 tf 下短文档排前；零命中不入结果', () {
      final docs = [
        doc('long', '项目知识库的使用说明，这里还有不少无关的填充句子用来拉长文档长度'),
        doc('short', '知识库索引'),
        doc('none', '天气预报说明天有雨'),
      ];
      final result = LexicalSearch.search('知识库', docs);
      // 两篇对「知识库」的各词项 tf 相同，唯一差异是长度 → 短者胜
      expect(result.hits.map((h) => h.id), ['short', 'long']);
    });

    test('同长度下 tf 高者排前（中文等长构造）', () {
      // 两个 5 字 Han 串 token 总数同为 9（n 个单字 + n-1 个二元组），
      // 唯一差异是「苹果」出现次数 —— 差异只能来自 tf。
      final docs = [
        doc('tf2', '苹果苹果梨'), // 苹果 ×2
        doc('tf1', '苹果橘子儿'), // 苹果 ×1
      ];
      final result = LexicalSearch.search('苹果', docs);
      expect(result.hits.map((h) => h.id), ['tf2', 'tf1']);
    });

    test('k 截断与 minScore', () {
      final docs = [
        doc('d1', '苹果'),
        doc('d2', '苹果好吃'),
        doc('d3', '苹果树'),
        doc('d4', '香蕉'),
      ];
      final top2 = LexicalSearch.search('苹果', docs, k: 2);
      // 同 tf，长度排序：苹果(3 tokens) < 苹果树(5) < 苹果好吃(8)
      expect(top2.hits.map((h) => h.id), ['d1', 'd3']);

      expect(LexicalSearch.search('苹果', docs, minScore: 1000).hits, isEmpty);
    });

    test('空查询 / 纯虚词查询 → 无结果', () {
      final docs = [doc('d1', '知识库内容')];
      expect(LexicalSearch.search('', docs).hits, isEmpty);
      // 的/了/吗 全在停用表，raw token 数 > 3 → 不触发短查询回退
      expect(LexicalSearch.search('的了吗', docs).hits, isEmpty);
    });

    test('查询词不在任何文档 → 无结果', () {
      final docs = [doc('d1', '知识库内容')];
      expect(LexicalSearch.search('量子纠缠', docs).hits, isEmpty);
    });

    test('同分按原始下标破平，排序确定', () {
      final docs = [doc('b', '苹果'), doc('a', '苹果')];
      final result = LexicalSearch.search('苹果', docs);
      expect(result.hits.map((h) => h.id), ['b', 'a']); // index 0 在前
    });
  });

  group('per-term 得分分解（为什么命中）', () {
    final docs = [
      doc('d1', '量子量子计算'),
      doc('d2', '量子计算进阶'),
      doc('d3', '知识库整理'),
    ];

    test('分项之和等于总分，按贡献降序', () {
      final result = LexicalSearch.search('量子知识库', docs);
      final d3 = result.hits.firstWhere((h) => h.id == 'd3');
      expect(d3.terms, isNotEmpty);
      var sum = 0.0;
      for (final t in d3.terms) {
        expect(t.tf, greaterThanOrEqualTo(1));
        expect(t.idf, greaterThan(0));
        expect(t.score, greaterThan(0));
        sum += t.score;
      }
      expect(d3.score, closeTo(sum, 1e-9));
      for (var i = 0; i < d3.terms.length - 1; i++) {
        expect(d3.terms[i].score, greaterThanOrEqualTo(d3.terms[i + 1].score));
      }
    });

    test('罕见词 idf 高于常见词；tf 记录命中次数', () {
      final result = LexicalSearch.search('量子知识库', docs);
      final d1 = result.hits.firstWhere((h) => h.id == 'd1');
      final d3 = result.hits.firstWhere((h) => h.id == 'd3');
      final liangzi = d1.terms.firstWhere((t) => t.term == '量子');
      final zhishi = d3.terms.firstWhere((t) => t.term == '知识');
      expect(liangzi.tf, 2); // d1 里出现两次
      expect(zhishi.tf, 1);
      expect(zhishi.idf, greaterThan(liangzi.idf)); // df 1 vs df 2
    });
  });

  group('tags / type 过滤', () {
    test('anyTag OR 语义，anyType 成员匹配，可叠加取交集', () {
      final docs = [
        doc('w1', '苹果', tags: ['工作']),
        doc('l1', '苹果', tags: ['生活'], type: 'style_sample'),
        doc('b1', '苹果', tags: ['工作', '生活']),
        doc('x1', '香蕉'),
      ];
      expect(
        LexicalSearch.search('苹果', docs, anyTag: ['生活']).hits
            .map((h) => h.id),
        ['l1', 'b1'],
      );
      expect(
        LexicalSearch.search('苹果', docs, anyType: ['style_sample']).hits
            .map((h) => h.id),
        ['l1'],
      );
      expect(
        LexicalSearch.search('苹果', docs,
            anyTag: ['生活'], anyType: ['style_sample']).hits.map((h) => h.id),
        ['l1'],
      );
    });

    test('空过滤器不设限', () {
      final docs = [doc('a', '苹果'), doc('b', '苹果', tags: ['工作'])];
      expect(LexicalSearch.search('苹果', docs).hits, hasLength(2));
    });
  });

  group('评测钩子 precision@k', () {
    final docs = [
      doc('d1', '苹果'),
      doc('d2', '苹果好吃'),
      doc('d3', '苹果树'),
      doc('d4', '香蕉'),
    ];

    test('precision / recall / 逐命中相关性', () {
      final result =
          LexicalSearch.search('苹果', docs, relevantIds: {'d1', 'd3'});
      final eval = result.eval!;
      // 命中序：d1(3 tokens) < d3(5) < d2(8)
      expect(result.hits.map((h) => h.id), ['d1', 'd3', 'd2']);
      expect(eval.relevantTotal, 2);
      expect(eval.relevantInTopK, 2);
      expect(eval.hitsReturned, 3);
      expect(eval.precisionAtK, closeTo(2 / 3, 1e-9));
      expect(eval.recallAtK, 1.0);
      expect(eval.hitIsRelevant, [true, true, false]);
    });

    test('不传 relevantIds → eval 为 null', () {
      expect(LexicalSearch.search('苹果', docs).eval, isNull);
    });

    test('命中不足 k 时分母取实际命中数（口径钉死）', () {
      final few = [doc('d1', '苹果'), doc('d5', '橘子')];
      final result =
          LexicalSearch.search('苹果', few, k: 5, relevantIds: {'d1'});
      final eval = result.eval!;
      expect(eval.hitsReturned, 1);
      expect(eval.k, 5);
      expect(eval.precisionAtK, 1.0); // 1/1，不是 1/5
    });

    test('全部不相关 → precision / recall 皆 0', () {
      final result = LexicalSearch.search('苹果', docs, relevantIds: {'d4'});
      expect(result.eval!.precisionAtK, 0.0);
      expect(result.eval!.recallAtK, 0.0);
    });
  });

  group('单字查询（超越 legacy）', () {
    test('legacy 只切二元组，单字查询永远空手；这里可命中', () {
      final docs = [doc('d1', '这台机器很好用'), doc('d2', '今天天气不错')];
      final result = LexicalSearch.search('机', docs);
      expect(result.hits, hasLength(1));
      expect(result.hits.single.id, 'd1');
    });
  });
}
