// 远端拉取服务 PackFetchService 的单测：清单/包体两级下载 + core 校验的
// 直连行为（本地 HttpServer 假服务器，与 core http_json_test.dart 的
// MockServer 同一构造方式）；外加 core HttpJson.get 的尺寸护栏（超 2MB 即
// 断，Content-Length 说谎也拦得住——服务层拿不到半截数据）。
//
// 读超时（40s）不在此覆盖：等待时长超出测试预算，护栏的「超限断开」与
// 「传输失败归一成可读错误」由下列分支钉住；超时路径与既有 post 缓冲路径
// 共用同一 readTimer 机制（http_json.dart 内同款代码）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chartools_app/application/pack_fetch_service.dart';
import 'package:chartools_core/chartools_core.dart' as kb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = PackFetchService();

  /// 起一个只回应 [handler] 的本地服务器（随机端口，127.0.0.1 回环）。
  Future<HttpServer> start(Future<void> Function(HttpRequest req) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        await handler(req);
      } catch (_) {
        // 客户端提前断开（超限 abort）时服务器的迟到失败不算数。
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
    return server;
  }

  /// 回一段字节并收线。
  Future<void> reply(HttpRequest req, List<int> body, {int status = 200}) async {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.add(body);
    await req.response.close();
  }

  String goodManifest(String packUrl) => jsonEncode({
        'format': 'jev-expert-remote-manifest/1',
        'packs': [
          {'id': 'demo-pack', 'version': '1.0.0', 'url': packUrl},
        ],
      });

  String goodPack() => jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'demo-pack', 'version': '1.0.0', 'name': '演示包'},
        'experts': [
          {'id': 'followup.0', 'name': '跟单0', 'promptText': '称呼：您', 'domain': '销售'},
        ],
      });

  test('fetchRemoteManifest：好清单 → 条目解析出来（id/version/url）', () async {
    late final HttpServer server;
    server = await start((req) async {
      await reply(
          req, utf8.encode(goodManifest('http://127.0.0.1:${server.port}/p.json')));
    });
    try {
      final entries = await service
          .fetchRemoteManifest('http://127.0.0.1:${server.port}/m.json');
      expect(entries, hasLength(1));
      expect(entries.single.id, 'demo-pack');
      expect(entries.single.version, '1.0.0');
      expect(entries.single.url, 'http://127.0.0.1:${server.port}/p.json');
    } finally {
      await server.close(force: true);
    }
  });

  test('fetchRemoteManifest：格式不支持 / 非 JSON / 空清单 → FormatException 可读',
      () async {
    late final HttpServer server;
    server = await start((req) async {
      if (req.uri.path == '/badformat') {
        await reply(req,
            utf8.encode(jsonEncode({'format': 'nope/9', 'packs': []})));
      } else if (req.uri.path == '/notjson') {
        await reply(req, utf8.encode('这不是 JSON'));
      } else {
        await reply(req, utf8.encode(''));
      }
    });
    try {
      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        service.fetchRemoteManifest('$base/badformat'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('清单格式不支持'))),
      );
      await expectLater(
        service.fetchRemoteManifest('$base/notjson'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('清单不是合法 JSON'))),
      );
      await expectLater(
        service.fetchRemoteManifest('$base/empty'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('清单是空的'))),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('fetchPack：好包返回原文（存档存原文不重排）；坏包（缺 experts）校验失败拒收',
      () async {
    late final HttpServer server;
    server = await start((req) async {
      if (req.uri.path == '/good') {
        await reply(req, utf8.encode(goodPack()));
      } else {
        // 缺 experts 数组：core PackCodec 清单级校验拒收。
        await reply(req, utf8.encode(jsonEncode({
          'format': 'jev-expert-pack/1',
          'pack': {'id': 'demo-pack', 'version': '1.0.0'},
        })));
      }
    });
    try {
      final base = 'http://127.0.0.1:${server.port}';
      final raw = await service.fetchPack('$base/good');
      expect(raw, goodPack()); // 原文透传
      await expectLater(
        service.fetchPack('$base/noexperts'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('包体校验失败'))),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('HTTP 404 → FormatException 带状态码；非 UTF-8 响应 → 可读错误', () async {
    late final HttpServer server;
    server = await start((req) async {
      if (req.uri.path == '/missing') {
        await reply(req, utf8.encode('not found'), status: 404);
      } else if (req.uri.path == '/binary') {
        await reply(req, <int>[0xFF, 0xFE, 0x7B, 0x7D]);
      } else {
        await reply(req, utf8.encode('ok'));
      }
    });
    try {
      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        service.fetchPack('$base/missing'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('HTTP 404'))),
      );
      await expectLater(
        service.fetchPack('$base/binary'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('UTF-8'))),
      );
    } finally {
      await server.close(force: true);
    }
  });

  group('core HttpJson.get 尺寸护栏（2MB 上限，防 oversized）', () {
    test('超过 2MB 的响应被中止：半截数据一个字节都不上交', () async {
      // 2MB+1 个 'x'：单块上线，客户端逐块计数在 2MB 处截停。
      final big = List<int>.filled(2 * 1024 * 1024 + 1, 120);
      late final HttpServer server;
      server = await start((req) async {
        req.response.statusCode = 200;
        await req.response.addStream(Stream<List<int>>.value(big));
        await req.response.close();
      });
      try {
        // 底层通道：ApiException，文案可读。
        await expectLater(
          kb.HttpJson.get('http://127.0.0.1:${server.port}/big', '下载包体'),
          throwsA(isA<kb.ApiException>()
              .having((e) => e.message, 'message', contains('大小上限'))),
        );
        // 服务层包装后同样拒收（校验不过不落盘的前半句：下载就拦）。
        await expectLater(
          service.fetchPack('http://127.0.0.1:${server.port}/big'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('大小上限'))),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('恰好 2MB 以内的响应正常通过（护栏不误伤正常量级）', () async {
      final ok = List<int>.filled(2 * 1024 * 1024, 120); // 恰好 2MB
      late final HttpServer server;
      server = await start((req) async {
        req.response.statusCode = 200;
        await req.response.addStream(Stream<List<int>>.value(ok));
        await req.response.close();
      });
      try {
        final text =
            await kb.HttpJson.get('http://127.0.0.1:${server.port}/ok', '下载包体');
        expect(text.length, ok.length);
      } finally {
        await server.close(force: true);
      }
    });
  });
}
