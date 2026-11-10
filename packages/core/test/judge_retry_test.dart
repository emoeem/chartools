import 'package:chartools_core/src/jev_client/judge_retry.dart';
import 'package:test/test.dart';

/// 对拍旧仓库 `JudgeRetryTest.kt`。
///
/// 优化报告把防御性重试标成「待生产验证」的存量：在生产上验证不了，就钉成
/// 明文规则。重试的前提是「这个 body 被拒了」——是关于**拒收原因**的判断，
/// 不是「任意 4xx 都再试一次」。
void main() {
  test('端点拒收的 body：丢弃富化字段重试一次', () {
    // 400/422 —— 形状本身就是投诉；413 —— history 正是撑大 body 的字段；
    // 415 —— 端点不收的字段格式；404 —— body 根本没到在乎它的 handler。
    for (final status in const [400, 404, 413, 415, 422]) {
      expect(JudgeRetry.shouldDropEnrichment(status), isTrue,
          reason: 'HTTP $status 应当丢弃 background/history 重试');
    }
  });

  test('密钥不对不是 body 的问题', () {
    // 401/403：换任何 body 都不会过，重试只会把真正的消息多拖一个往返。
    expect(JudgeRetry.shouldDropEnrichment(401), isFalse);
    expect(JudgeRetry.shouldDropEnrichment(403), isFalse);
  });

  test('被要求减速也不是 body 的问题', () {
    // 408/429：服务端在叫我们慢下来；429 在浮出为 ApiException 之前已经被
    // HTTP 层重试过三次，这里立刻再发等于把负载翻倍。
    expect(JudgeRetry.shouldDropEnrichment(408), isFalse);
    expect(JudgeRetry.shouldDropEnrichment(429), isFalse);
  });

  test('服务端自己的故障不算到字段头上', () {
    for (final status in const [500, 502, 503, 529]) {
      expect(JudgeRetry.shouldDropEnrichment(status), isFalse,
          reason: 'HTTP $status 是服务端的问题，不是字段的');
    }
  });

  test('没有状态码就没有证据', () {
    // 超时 / 断网：连「为什么被拒」都不知道，谈不上丢弃字段。
    expect(JudgeRetry.shouldDropEnrichment(null), isFalse);
  });

  test('不是失败的码不重试', () {
    for (final status in const [0, 3, 200, 302, 600]) {
      expect(JudgeRetry.shouldDropEnrichment(status), isFalse,
          reason: 'HTTP $status 不是「body 被拒」');
    }
  });
}
