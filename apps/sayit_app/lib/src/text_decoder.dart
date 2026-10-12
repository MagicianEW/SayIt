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

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset_codec/charset_codec.dart';

/// 一次成功的文本解码，带上**实际用的编码**。
///
/// 界面上要如实告诉用户"这个文件是按 GB18030 读进来的"，
/// 否则他只会奇怪为什么以前导入出乱码的文件现在能读了。
class DecodedText {
  final String text;

  /// 人类可读的编码名：UTF-8 / GB18030 / UTF-16 / Latin-1。
  final String encoding;

  const DecodedText(this.text, this.encoding);
}

/// 去掉 UTF-8 BOM。记事本存 UTF-8 会带 EF BB BF，
/// 不去掉的话第一句开头会多出一个不可见字符。
String stripUtf8Bom(String text) {
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    return text.substring(1);
  }
  return text;
}

/// 判断解出来的文本像不像正常文字。
///
/// 为什么要判：GB18030 的合法字节范围极大（首字节 0x81-0xFE，
/// 次字节 0x40-0xFE 排除 0x7F），几乎任何字节序列都能"严格解码成功"。
/// 所以光看「解码没抛异常」不足以说明它就是 GB18030 —— 一个西欧
/// Windows-1252 文件也可能被解成一堆看不出所以然的汉字。
///
/// 这里用一个保守的启发式：控制符（C0 除 \t\n\r、C1）占比不能太高。
/// 真正的中文文件里控制符几乎为 0，而被误判的文件通常会带一堆。
/// 这只是启发式，所以判不准时仍然由界面弹窗让用户选，见 [tryDecodeText]。
bool looksLikeText(String text) {
  if (text.isEmpty) return false;
  var control = 0;
  for (final r in text.runes) {
    if (r == 0x09 || r == 0x0A || r == 0x0D) continue; // tab / LF / CR 正常
    if (r < 0x20 || (r >= 0x7F && r <= 0x9F)) control++;
  }
  return control * 20 <= text.length; // 控制符占比 < 5%
}

/// 从字节解码 UTF-16。
///
/// `dart:convert` **没有** UTF-16 的编解码器（只有 UTF-8 / ASCII / Latin-1），
/// 得自己按 BOM 指定的字节序把字节两两拼成 UTF-16 码元，
/// 再用 `String.fromCharCodes` 组装 —— 它会正确合并合法的代理对。
///
/// [bytes] 必须**不含** BOM（本函数由 [tryDecodeText] 在剥掉 BOM 后调用）。
String _decodeUtf16Body(Uint8List bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final lo = bytes[i];
    final hi = bytes[i + 1];
    units.add(littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi));
  }
  return String.fromCharCodes(units);
}

/// 尝试按 UTF-8 → GB18030 依次解码。
///
/// 返回 `null` 表示两种都解不了（调用方应弹窗让用户在 Latin-1 / 取消之间选）。
/// 返回非 null 时，[DecodedText.encoding] 说明实际用的是哪个。
///
/// ## 为什么要自己解，而不是交给 `File.readAsString(encoding: ...)`
///
/// 那个 API 要求**事先**知道编码，而这里的场景正是"不知道"。
/// 而且它失败时只能拿到一个 FormatException，拿不回原始字节做二次尝试。
///
/// ## 顺序为什么是 UTF-16 → UTF-8 → GB18030
///
/// UTF-16 带明确 BOM（FF FE / FE FF），不会和中文文件混淆，所以先判它、
/// 判完就是确定结果。GB18030 放最后：它的合法字节范围极大，
/// 几乎什么字节都能"解成功"，放前面会把不该当中文的文件吃掉。
DecodedText? tryDecodeText(Uint8List bytes) {
  if (bytes.isEmpty) return null;

  // 1. UTF-16：有明确 BOM，判定不含糊
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return DecodedText(
        _decodeUtf16Body(bytes.sublist(2), littleEndian: true),
        'UTF-16',
      );
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return DecodedText(
        _decodeUtf16Body(bytes.sublist(2), littleEndian: false),
        'UTF-16',
      );
    }
  }

  // 2. UTF-8（绝大多数文件走这条，strict 模式：非法字节抛异常而不是
  //    悄悄塞一堆 U+FFFD）
  try {
    return DecodedText(stripUtf8Bom(utf8.decode(bytes)), 'UTF-8');
  } catch (_) {
    // 不是 UTF-8，继续试
  }

  // 3. GB18030（中文 Windows 导出的 .txt 基本都是 GBK/GB18030）
  final gb = tryDecodeBytes(bytes, encoding: 'gb18030');
  if (gb != null && looksLikeText(gb)) {
    return DecodedText(stripUtf8Bom(gb), 'GB18030');
  }

  // GB18030 能解但解出来不像文字（很可能是西欧文件），或者根本解不了。
  // 都不自动采纳 —— 交给界面弹窗问用户。
  return null;
}

/// GB18030 严格解码，供弹窗里的「按 GB18030 读取」按钮用。
/// 解不了返回 null。
String? tryDecodeGb18030(Uint8List bytes) =>
    tryDecodeBytes(bytes, encoding: 'gb18030');
