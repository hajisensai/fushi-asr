/// 出站 HTTP 装配的单一入口（模型下载走这里）。
///
/// 抽包前这里是 Hibiki 的 `createAppHttpClient()`——它把应用的代理策略、局域网直连
/// 闸门和连接超时装配在一起。库不能假设宿主有那一套，所以做成**可替换的工厂**：
/// 默认实现读 `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` 环境变量
/// （`HttpClient.findProxyFromEnvironment` 的标准语义），Flutter 宿主直接把自己的
/// 工厂装进来即可。
library;

import 'dart:io';

/// 公网出站的默认**连接建立**超时（DNS + TCP + 代理隧道 + TLS 握手）。
///
/// 只掐连接建立，不掐响应体传输：本层同时服务「一次 API 往返」与「几百 MB 模型
/// 下载」，给响应体设一刀切时限会掐断后者。
const Duration kAsrHttpConnectionTimeout = Duration(seconds: 20);

/// HTTP 客户端工厂签名。
typedef AsrHttpClientFactory = HttpClient Function({Duration? connectionTimeout});

/// 当前工厂。宿主可整体替换。
AsrHttpClientFactory asrHttpClientFactory = defaultAsrHttpClient;

/// 默认工厂：按环境变量选代理出口。
HttpClient defaultAsrHttpClient({
  Duration? connectionTimeout = kAsrHttpConnectionTimeout,
}) {
  final HttpClient client = HttpClient();
  if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
  client.findProxy = (Uri uri) =>
      HttpClient.findProxyFromEnvironment(uri, environment: Platform.environment);
  return client;
}

/// 建一个出站客户端。
HttpClient createAsrHttpClient({
  Duration? connectionTimeout = kAsrHttpConnectionTimeout,
}) =>
    asrHttpClientFactory(connectionTimeout: connectionTimeout);
