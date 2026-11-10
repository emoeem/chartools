import 'package:chartools_app/application/capture_session.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// G3 置信度门控的边界钉子：阈值本身（0.5）算「不可信」。
///
/// 复核发现的漏洞：OCR 快照带标题且恰好一条 unknown-speaker 消息时，通道
/// 契约（CaptureService.kt 的扣分算术）给出的是精确 0.5——双精度下
/// 0.6-0.1 就是 0.5，不是 0.4999…（数值由 Kotlin 侧
/// SnapshotConfidenceContractTest.titledOcrWithSingleUnknownSpeakerSitsExactlyOnGateThreshold
/// 钉住）。门控曾用 `<`，把 p0-plan G3 点名的「说话人不可归属 → 不自动分析」
/// 贴线放行了；现在比较收敛到 [CaptureSession.shouldConfirm] 一处（采集流与
/// 桌面流共用），本文件钉它的边界语义。
void main() {
  group('CaptureSession.shouldConfirm（G3 门控边界）', () {
    test('恰好在阈值上的精确 0.5 挂起，不能贴线放行', () {
      const snapshot = ChatSnapshot(confidence: 0.5);
      expect(CaptureSession.shouldConfirm(snapshot), isTrue);
    });

    test('通道 JSON 解析不挪边界：confidence=0.5 进门即挂起', () {
      // 采集侧 snapshotJson 发什么 Dart 就认什么：0.5 原样到达门控。
      final snapshot = ChatSnapshot.fromJson({
        'title': '小美',
        'provenance': 'ocr',
        'confidence': 0.5,
        'uncertain': ['发言人未知'],
        'messages': [
          {'side': 'me', 'text': '在'},
        ],
      });
      expect(snapshot.confidence, 0.5);
      expect(CaptureSession.shouldConfirm(snapshot), isTrue);
    });

    test('阈值之下挂起（越界夹回的下限 0.2 也不例外）', () {
      expect(CaptureSession.shouldConfirm(const ChatSnapshot(confidence: 0.45)),
          isTrue);
      expect(CaptureSession.shouldConfirm(const ChatSnapshot(confidence: 0.2)),
          isTrue);
    });

    test('阈值之上照常自动分析（a11y 缺省 1.0、OCR 基线 0.6 都放行）', () {
      expect(CaptureSession.shouldConfirm(const ChatSnapshot()), isFalse);
      expect(CaptureSession.shouldConfirm(const ChatSnapshot(confidence: 0.6)),
          isFalse);
      // 贴线之上一点点也是放行——边界只含 0.5 本身。
      expect(CaptureSession.shouldConfirm(const ChatSnapshot(confidence: 0.55)),
          isFalse);
    });
  });
}
