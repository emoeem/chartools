/// 远端资产包拉取服务 —— 专家页「从远端导入」的网络手指。
///
/// 职责边界（core 既定：expert_pack.dart 头注释「清单 URL 与包体下载都由
/// app 层负责（core 不发请求）」）：
/// - HTTP 细节走 core `HttpJson.get`（读超时 40s / 连接超时 15s / 响应体
///   2MB 上限都在 core，本文件零 HTTP 代码）；
/// - 解析与校验走 core `RemoteManifestCodec` / `PackCodec`（规则唯一出处，
///   本文件**零自有校验规则**，只有失败文案的包装——包装成
///   [FormatException] 且 message 用户可读，控制器直接转 problem 上屏）；
/// - 「校验不过不落盘」在 [fetchPack] 兑现：包 JSON 先过 core PackCodec
///   严格校验再返回，控制器拿到的一定是 core 认得的清单原文。
///
/// 失败统一抛 [FormatException]（message 中文可读）；取消
/// （RequestCancelledException）不在本服务的语义里——清单/包体下载没有
/// scope 可传，用户在页面上取消的是整页操作，不单是下载。
library;

import 'package:chartools_core/chartools_core.dart' as kb;

class PackFetchService {
  const PackFetchService();

  /// 拉取远端清单（「货架目录的目录」）并解析。
  ///
  /// 返回可用条目（RemotePackEntry：id/version/url/…）。清单级校验失败
  /// （非 JSON / 缺 format / 格式不支持 / 无可用条目）抛 [FormatException]；
  /// 条目级跳过（清单作者写坏的个别条目）不拦——core 解析已跳过并计数，
  /// 剩下的条目照常可用（调用方如需警告可从 entries 的缺失自行判断）。
  Future<List<kb.RemotePackEntry>> fetchRemoteManifest(String url) async {
    final raw = await _download(url, '拉取清单');
    final parsed = kb.RemoteManifestCodec.parse(raw);
    if (!parsed.ok) {
      throw FormatException(
          parsed.problem.isEmpty ? '远端清单不可用' : parsed.problem);
    }
    return parsed.entries;
  }

  /// 拉取一个包 JSON。**先过 core PackCodec 严格校验再返回**（校验不过
  /// 不落盘——包体内容在进控制器之前就被拒收）；返回包清单**原文**（存档
  /// 存原文不重排，与既有安装路径同一约定）。
  Future<String> fetchPack(String url) async {
    final raw = await _download(url, '下载包体');
    final check = kb.PackCodec.parse(raw);
    if (!check.ok) {
      throw FormatException(
          check.problem.isEmpty ? '包体校验失败' : '包体校验失败：${check.problem}');
    }
    return raw;
  }

  /// GET 下载 + 错误包装：HTTP/传输层失败已由 core HttpJson.get 归一成
  /// ApiException（message 含 route + 状态码 + 可读原因），这里只把它转成
  /// [FormatException] 让上层一条 catch 就能接住。
  Future<String> _download(String url, String route) async {
    try {
      return await kb.HttpJson.get(url, route);
    } on kb.RequestCancelledException {
      rethrow;
    } on kb.ApiException catch (e) {
      throw FormatException(e.message);
    }
  }
}
