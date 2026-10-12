// Copyright (C) 2026 SayIt Contributors
//
// This file is part of SayIt.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

/// 把底层报错整理成用户看得懂的一句话。
///
/// ## 为什么需要这个
///
/// 合成失败时 `sayit-poc` 会把 Python 子进程的 stderr 原样带回来，其中包含
/// edge_tts 的完整请求 URL。实测一次 403 的原始报错有 397 个字符，
/// **362 个**是 URL 里的 `TrustedClientToken` / `ConnectionId` / `Sec-MS-GEC`
/// —— 这些是微软用来校验握手的一次性令牌和连接号，用户完全用不上，
/// 但它们会占满状态栏那一个小灰框，把真正有用的一行挤到看不见。
///
/// 而且原始报错只说 `403 Invalid response status`，没说是**什么原因**。
/// 实测最常见的成因是网络出口被微软拒（代理 / VPN 节点的 IP），
/// 这个如果不翻译出来，用户只会反复重试。
///
/// ## 用法
///
/// `sanitizeTtsError` 返回可直接显示给用户的文本；不该改动的部分保持原样。
String sanitizeTtsError(String raw) {
  var text = raw.trim();

  // 1. 砍掉 URL 参数（含 DRM 令牌）。edge_tts 的报错形如：
  //    stream: 403, message='Invalid response status', url='wss://...?Sec-MS-GEC=...'
  text = text.replaceAll(RegExp(r",\s*url='[^']*'"), '');
  // 双引号变体，稳妥起见也覆盖
  text = text.replaceAll(RegExp(r',\s*url="[^"]*"'), '');

  // 2. 连续空行/空白压平，避免删掉 URL 后留下大片空白
  text = text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();

  // 3. 403 单独拎出来说清楚。这是最常见的失败原因，而且原始信息完全没提。
  final isForbidden = RegExp(r'\b403\b|Invalid response status').hasMatch(text);
  if (isForbidden) {
    // 只保留末尾的状态码/原因，别把整句 aiohttp 异常抄一遍
    final reason = text.contains('Invalid response status')
        ? '微软拒绝了本次连接（403 Invalid response status）'
        : '微软拒绝了本次连接（403）';
    return '$reason\n'
        '常见原因：网络出口被拒。若你在用代理 / VPN，换一个节点或关掉代理再试；'
        '公司内网也可能被限制。其余信息：$text';
  }

  return text;
}
