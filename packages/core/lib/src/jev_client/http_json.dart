import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'api_exception.dart';
import 'http_scope.dart';
import 'jsonx.dart';

/// Shared POST-JSON helper: UTF-8 body, exponential backoff on 429/5xx/transport,
/// no retry on other 4xx, and every failure normalized to [ApiException]. Keys
/// are passed in per call and never logged, and are redacted out of error text.
///
/// Runs on `dart:io` [HttpClient] so that an abandoned request can be *cut*
/// (via `abort()`) rather than merely abandoned — one wedged request used to
/// hold its round's thread for good in the Kotlin original.
abstract final class HttpJson {
  static const int maxAttempts = 3;
  static const int connectTimeoutMs = 15 * 1000;
  static const int readTimeoutMs = 40 * 1000;

  /// Backoff between attempts. Mutable so a unit test can collapse the three
  /// attempts from ~1.5 s of sleeping to ~3 ms; production never writes it.
  static int retryBackoffMs = 500;

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: connectTimeoutMs);

  /// One authenticated POST shape every route uses: UTF-8 JSON body, bearer key,
  /// caller extras. Shared with the SSE path so a streaming request cannot drift
  /// from the non-streaming one.
  static Map<String, String> jsonRequestHeaders(
    String key,
    Map<String, String> extraHeaders,
  ) =>
      {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json; charset=utf-8',
        ...extraHeaders,
      };

  /// POST 一段 JSON，返回解码后的 JSON 对象。每个 HTTP 或传输层失败都归一成
  /// [ApiException]；[route] 只用于组错误文案。
  ///
  /// fix(kimi-review #9)：请求体在重试循环**外**编码一次。jsonEncode 抛的
  /// JsonUnsupportedObjectError 是调用方传参错误（body 里有不可序列化的
  /// 对象），与网络无关——原先在循环内编码，会被下面的 catch-all 当传输
  /// 失败白白重试满 3 次。编码失败直接抛参数错误，一次都不出网。
  static Future<Map<String, dynamic>> post(
    String url,
    String key,
    Map<String, dynamic> body,
    String route, {
    Map<String, String> extraHeaders = const {},
    HttpScope? scope,
  }) async {
    final String encodedBody;
    try {
      encodedBody = jsonEncode(body);
    } catch (e) {
      throw ArgumentError('请求体无法编码为 JSON（调用方传参错误）：$e');
    }
    var attempt = 0;
    ApiException? last;
    while (attempt < maxAttempts) {
      if (_isAborted(scope)) throw RequestCancelledException(route);
      try {
        return await _once(url, key, encodedBody, route, extraHeaders, scope);
      } on RequestCancelledException {
        rethrow;
      } on ApiException catch (e) {
        if (_isAborted(scope)) throw RequestCancelledException(route);
        // Client errors are final — except 429 (rate limit) and 529
        // (overloaded), which are the two that mean "come back later".
        // 5xx 与传输失败按服务端问题重试。
        final status = e.status;
        if (status != null &&
            status >= 400 &&
            status < 500 &&
            status != 429 &&
            // fix(#8 DS-3)：529 显式入白名单。529 不落 [400, 500) 区间，这一项
            // 今天恒真——但上面注释承诺的「429 与 529 是仅有的两个可重试的
            // 客户端语义码」必须由代码显式背着：将来若有人把区间扩成
            // [400, 600) 或改写判定，这条挡得住 529 被静默改成不重试。
            status != 529) {
          throw e;
        }
        last = e;
        attempt++;
        if (attempt < maxAttempts) await _sleep(attempt);
      } catch (e) {
        if (_isAborted(scope)) throw RequestCancelledException(route);
        last = ApiException(route, null, describe(e));
        attempt++;
        if (attempt < maxAttempts) await _sleep(attempt);
      }
    }
    throw last ?? ApiException(route, null, '请求失败');
  }

  /// One Server-Sent-Events round trip (opt-in streaming, off by default).
  ///
  /// Runs until the server closes the stream, a `data: [DONE]` sentinel lands,
  /// an error occurs, or [scope] is cancelled. Returns the concatenated `data:`
  /// payloads; [onData] sees each payload as it lands, which is the whole point
  /// (the card can show text while the model is still writing).
  ///
  /// Deliberately NOT retried: a half-delivered stream that restarts would show
  /// the same sentence twice. The caller falls back to the buffered path instead.
  static Future<String> stream(
    String url,
    String key,
    Map<String, dynamic> body,
    String route, {
    Map<String, String> extraHeaders = const {},
    HttpScope? scope,
    required void Function(String data) onData,
  }) async {
    HttpClientRequest? request;
    final cancel = () => request?.abort(RequestCancelledException(route));
    scope?.attach(cancel);
    try {
      final req = await _client.openUrl('POST', Uri.parse(url));
      request = req;
      // Kotlin 的 `forEach(req.headers::set)` 写法在 Dart 里不存在（`::` 不是
      // Dart 语法）；等价物是实例方法 tear-off `req.headers.set`。
      jsonRequestHeaders(key, extraHeaders).forEach(req.headers.set);
      req.headers.set('Accept', 'text/event-stream');
      req.write(jsonEncode(body));

      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        final text = await resp.transform(utf8.decoder).join();
        // fix(kimi-review #10)：脱敏走 [redactKey]，编码与片段形态也抹掉。
        final safeText = redactKey(text, key);
        throw ApiException(
            route, resp.statusCode, safeText.ifBlank('（响应体为空）'));
      }

      final buffer = StringBuffer();
      // [_ssePayloads] 在 [DONE] 处自己结束事件流，await for 在这里自然走完，
      // 不需要中途 break：中途取消一个正停在底层响应流上的 async* 生成器，
      // 其取消要等到生成器从那个 await 上醒来才完成，客户端就会被不关连接
      // 的服务器拖到超时。流走完后 abort() 把连接收掉，不等服务器关。
      await for (final payload in _ssePayloads(resp)) {
        buffer.write(payload);
        buffer.write('\n');
        onData(payload);
      }
      request.abort(); // 与 Kotlin 的 source.cancel() 对齐：读完即收线。
      return buffer.toString();
    } on RequestCancelledException {
      rethrow;
    } on ApiException {
      rethrow;
    } catch (e) {
      if (_isAborted(scope)) throw RequestCancelledException(route);
      throw ApiException(route, null, describe(e));
    } finally {
      scope?.detach(cancel);
    }
  }

  /// GET 下载的响应体大小上限（字节）：远端清单与包体都是**不可信数据**，
  /// 流式读取逐块计数，超限立即 abort 断开——Content-Length 说谎时也要兜得住，
  /// 防止恶意/出错的服务器用一个超大响应打爆内存。正常量级：清单几 KB、
  /// 331 位专家的完整目录包约 200 KB，2MB 已是十倍余量。
  static const int maxDownloadBytes = 2 * 1024 * 1024;

  /// GET 一段 UTF-8 文本（远端清单 / 包体下载的底层通道；app 层
  /// PackFetchService 负责其上的解析与校验）。带读超时（与缓冲路径同一
  /// [readTimeoutMs]，连接超时在 [_client] 上统一 15s）与 [maxBytes] 大小
  /// 上限；每个 HTTP 或传输层失败都归一成 [ApiException]（与 [post] 同一
  /// 口径），非 2xx 的响应体片段进 snippet。
  ///
  /// **不重试**：清单/包体是幂等读，失败由调用方把可读 problem 交给界面、
  /// 用户重按一次即可——不像模型请求那样值得自动退避。
  static Future<String> get(
    String url,
    String route, {
    int maxBytes = maxDownloadBytes,
    HttpScope? scope,
  }) async {
    HttpClientRequest? request;
    final cancel = () => request?.abort(RequestCancelledException(route));
    scope?.attach(cancel);
    Timer? readTimer;
    try {
      final req = await _client.openUrl('GET', Uri.parse(url));
      request = req;
      readTimer = Timer(const Duration(milliseconds: readTimeoutMs), () {
        req.abort(SocketException('Read timed out'));
      });
      final resp = await req.close();
      final code = resp.statusCode;
      if (code < 200 || code > 299) {
        final text = await resp.transform(utf8.decoder).join();
        throw ApiException(route, code, text.ifBlank('（响应体为空）'));
      }
      // 流式读取 + 大小护栏：超限先断开连接再抛，半截数据一个字节都不上交。
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in resp) {
        total += chunk.length;
        if (total > maxBytes) {
          req.abort(SocketException('Response too large'));
          throw ApiException(route, code, '响应超过 ${(maxBytes / 1024 / 1024).toStringAsFixed(0)}MB 大小上限，已中止下载');
        }
        builder.add(chunk);
      }
      try {
        return utf8.decode(builder.takeBytes());
      } on FormatException {
        throw ApiException(route, code, '响应不是合法 UTF-8 文本');
      }
    } on RequestCancelledException {
      rethrow;
    } on ApiException {
      rethrow;
    } catch (e) {
      if (_isAborted(scope)) throw RequestCancelledException(route);
      throw ApiException(route, null, describe(e));
    } finally {
      readTimer?.cancel();
      scope?.detach(cancel);
    }
  }

  /// 把一条 SSE 响应体拆成一个个事件负载（多行 data 以 '\n' 连接）。
  ///
  /// 注释行（`: keep-alive` 心跳）与 `data: [DONE]` 都不是事件；读到 [DONE]
  /// 时事件流就地正常结束。这个终止必须发生在生成器内部（return），而不是
  /// 让调用方 break——后者对 async* 生成器是「取消」，要等生成器从底层响应
  /// 流的下一个事件上醒来才完成，服务器不关连接客户端就得干等。
  static Stream<String> _ssePayloads(HttpClientResponse resp) async* {
    final dataLines = <String>[];
    await for (final line
        in resp.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final payload = dataLines.join('\n');
          dataLines.clear();
          // [DONE] 只是结束哨兵，不作为事件交给调用方。
          if (payload.trim() == '[DONE]') return;
          yield payload;
        }
        continue;
      }
      if (line.startsWith(':')) continue; // SSE 注释/心跳
      if (line.startsWith('data:')) {
        var value = line.substring(5);
        if (value.startsWith(' ')) value = value.substring(1);
        dataLines.add(value);
      }
      // event:/id:/retry: 等字段 OpenAI 兼容流里不承载内容，忽略。
    }
    if (dataLines.isNotEmpty) {
      final payload = dataLines.join('\n');
      // 服务器在 [DONE] 后没有收尾空行就直接关流，同样不上抛哨兵。
      if (payload.trim() != '[DONE]') yield payload;
    }
  }

  /// One attempt. Throws [ApiException] for every HTTP or transport outcome.
  ///
  /// [encodedBody] 由调用方（[post]）在重试循环外编码好——本方法只管发送。
  static Future<Map<String, dynamic>> _once(
    String url,
    String key,
    String encodedBody,
    String route,
    Map<String, String> extraHeaders,
    HttpScope? scope,
  ) async {
    HttpClientRequest? request;
    final cancel = () => request?.abort(RequestCancelledException(route));
    scope?.attach(cancel);
    Timer? readTimer;
    try {
      final req = await _client.openUrl('POST', Uri.parse(url));
      request = req;
      jsonRequestHeaders(key, extraHeaders).forEach(req.headers.set);
      req.write(encodedBody);

      readTimer = Timer(const Duration(milliseconds: readTimeoutMs), () {
        // 有意为之：缓冲路径有读超时（推理模型的长流式走 stream()，无超时）。
        req.abort(SocketException('Read timed out'));
      });
      final resp = await req.close();
      final code = resp.statusCode;
      final text = await resp.transform(utf8.decoder).join();
      if (code == 429 || code == 529) {
        throw ApiException(route, code, '服务繁忙，已重试');
      }
      // Branch on the status code FIRST: reading the body must never be able to
      // lose it. A truncated or empty error body still has to surface as the
      // real status, otherwise a 401 gets retried as a transport failure.
      if (code < 200 || code > 299) {
        // fix(kimi-review #10)：脱敏走 [redactKey]，编码与片段形态也抹掉。
        final safeText = redactKey(text, key);
        throw ApiException(route, code, safeText.ifBlank('（响应体为空）'));
      }
      if (text.isBlank()) throw ApiException(route, code, '响应体为空');
      final decoded = tryDecodeObject(text);
      if (decoded == null) {
        throw ApiException(route, code, '响应不是 JSON 对象：${text.take(120)}');
      }
      return decoded;
    } finally {
      readTimer?.cancel();
      scope?.detach(cancel);
    }
  }

  static Future<void> _sleep(int attempt) =>
      Future.delayed(Duration(milliseconds: retryBackoffMs << attempt));

  static bool _isAborted(HttpScope? scope) => scope?.isCancelled ?? false;

  /// OpenRouter wants attribution headers; other hosts reject unknown ones
  /// politely.
  static Map<String, String> headersFor(String url) =>
      url.toLowerCase().contains('openrouter.ai')
          ? const {
              'HTTP-Referer': 'https://jev-assistant.local',
              'X-Title': 'Jev Assistant',
            }
          : const {};

  /// fix(kimi-review #10)：错误文案里的密钥脱敏。原先只 `replaceAll(key)`
  /// 精确匹配全文——服务端把 key URL 编码后回显（`%XX` 形态）、或截断回显
  /// key 的片段，都能原样漏出去。这里对三种形态都做替换：
  ///
  ///  1. key 原文（与原行为一致）；
  ///  2. `Uri.encodeComponent(key)`——表单 / 查询串里最常见的编码形态；
  ///  3. key 的前 8 与后 8 字符片段（仅 key 足够长时做：短 key 的片段太
  ///     通用，替换会把无关文案误伤成 [key]）。长度恰为 8 时前后片段相同，
  ///     第二次替换是空操作。
  ///
  /// 顺序有讲究：先整串后片段——整串替换后，残留的只有片段形态的回显。
  static String redactKey(String text, String key) {
    if (key.trim().isEmpty) return text;
    var out = text.replaceAll(key, '[key]');
    final encoded = Uri.encodeComponent(key);
    if (encoded != key && encoded.isNotEmpty) {
      out = out.replaceAll(encoded, '[key]');
    }
    if (key.length >= 8) {
      out = out
          .replaceAll(key.substring(0, 8), '[key]')
          .replaceAll(key.substring(key.length - 8), '[key]');
    }
    return out;
  }

  /// Human-readable transport failures (no key material ever appears here).
  static String describe(Object e) {
    final m = '${e.toString()} ${e.runtimeType}';
    return switch (e) {
      SocketException() when m.contains('timed out') =>
        '网络超时，请检查连接',
      SocketException() when m.contains('Failed host lookup') =>
        '域名解析失败，地址填错或无网络',
      SocketException() when m.contains('Connection refused') =>
        '无法连接该地址',
      HandshakeException() => 'HTTPS 证书校验失败',
      _ when m.toLowerCase().contains('timeout') => '网络超时，请检查连接',
      _ when m.contains('Failed host lookup') => '域名解析失败，地址填错或无网络',
      _ when m.contains('Connection refused') => '无法连接该地址',
      _ => e.toString(),
    };
  }
}

extension on String {
  // isBlank 写成方法而不是 getter：本文件里的调用点都是 Kotlin 习惯的
  // `isBlank()`，getter 会被当成 tear-off 之外的属性误用报错。
  bool isBlank() => trim().isEmpty;
  String ifBlank(String fallback) => trim().isEmpty ? fallback : this;
  String take(int n) => length <= n ? this : substring(0, n);
}
