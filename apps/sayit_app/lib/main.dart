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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/build_info.dart';
import 'src/text_segmenter.dart';
import 'src/voice_data.dart';

void main() {
  // 桌面端（Windows / Linux）必须显式初始化一次，just_audio 才知道该用哪套
  // 原生后端；不调用就会在首次播放时抛 MissingPluginException。macOS 用的是
  // just_audio 自带实现，这里默认只在 windows / linux 上注册，不影响 macOS。
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized();
  runApp(const SayItApp());
}

const _kExportPathKey = 'sayit_export_path';

/// 应用名。约定：英文名 `SayIt` 用于技术标识（可执行文件名、包名等），
/// 中文名「说吧」用于面向用户的显示。
///
/// 平台侧的元数据（Windows 窗口标题与 exe 属性、macOS 的 Info.plist 与
/// MainMenu.xib）没法引用这里的常量，它们由 `scripts/sync_app_name.py`
/// 统一同步 —— 改名请改那个脚本再跑一次，不要手改各平台文件。
const _kAppNameZh = '说吧';

/// 见 [_kAppNameZh]。界面里目前只用得到中文名，英文名留给需要显示
/// 技术标识的场景（例如关于对话框的补充说明）。
const _kAppNameEn = 'SayIt';

/// edge_tts 的输出格式是**固定的**、不可配置：
/// `audio-24khz-48kbitrate-mono-mp3`（24kHz / 48kbps CBR / 单声道）。
/// 6.x 与 7.x 的 `Communicate` 都不接受 `output_format` 参数，
/// 格式字符串在 edge_tts 内部是写死的。所以这里没有"请求格式"这回事，
/// 只有"如实使用真实格式"。
const _kAudioExtension = 'mp3';

/// 48 kbps CBR → 6000 字节/秒。用字节数可以**精确**换算时长，
/// 逐句高亮的时间轴不再靠边界事件累加（那样会漂移）。
const _kBytesPerMs = 6.0;

/// 句间停顿功能已移除。
///
/// 原因：要在音频里插入静音，必须能改字节流。edge_tts 输出的是固定编码的
/// MP3（48kbps CBR），插静音得先解码成 PCM、拼完再编码回去，
/// 而本项目没有内置 MP3 编码器；硬拼无声帧又容易让解码器爆音。
/// 所以句间停顿整体删掉，交给 TTS 自己在句号/问号/叹号后自然停。

class SayItApp extends StatelessWidget {
  const SayItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _kAppNameZh,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const SayItHomePage(),
    );
  }
}

class SynthesisResult {
  final Uint8List audio;
  final int sampleRate;
  final int channels;
  final String format;
  final List<WordBoundary> boundaries;

  SynthesisResult({
    required this.audio,
    required this.sampleRate,
    required this.channels,
    required this.format,
    required this.boundaries,
  });
}

class WordBoundary {
  final int textOffset;
  final int textLength;
  final double audioOffsetMs;
  final double durationMs;
  final String text;
  final String boundaryType;

  WordBoundary({
    required this.textOffset,
    required this.textLength,
    required this.audioOffsetMs,
    required this.durationMs,
    required this.text,
    required this.boundaryType,
  });
}

/// 把多个句子的 MP3 字节拼成一整段（直接拼接，不插入静音）。
class _MixedAudio {
  /// 整段 MP3 字节（CBR 48kbps，每秒 6000 字节 → 时长 = bytes / 6000 秒）。
  final Uint8List bytes;
  /// 每句在拼接后音频中的起始毫秒偏移（与 `bytes` 长度一一对应）。
  final List<int> sentenceOffsetsMs;

  _MixedAudio({
    required this.bytes,
    required this.sentenceOffsetsMs,
  });
}

/// 界面已销毁时用来中断正在进行的合成 / 导出流程。
class _CancelledException implements Exception {
  const _CancelledException();
}

class SayItHomePage extends StatefulWidget {
  const SayItHomePage({super.key});

  @override
  State<SayItHomePage> createState() => _SayItHomePageState();
}

class _SayItHomePageState extends State<SayItHomePage> {
  final _textController = TextEditingController();
  final _segmenter = const TextSegmenter();
  final _audioPlayer = AudioPlayer();

  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  List<Sentence> _sentences = [];
  List<int> _sentenceAudioOffsetsMs = [];
  int _currentSentenceIndex = -1;
  bool _isGenerating = false;
  bool _isExporting = false;
  String? _statusMessage;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  Set<String> _availableVoices = {};
  bool _isScanningVoices = true;
  bool _voiceScanFailed = false;

  String _selectedVoice = 'zh-CN-XiaoxiaoNeural';
  String _selectedLanguage = 'zh-CN';
  String _selectedGender = 'female';
  double _speed = 1.0;
  double _pitch = 0.0;
  double _volume = 1.0;
  String? _exportPath;

  List<VoiceInfo> get _filteredVoices {
    if (_isScanningVoices) return [];
    // 扫描失败时回退到内置全量表，保证界面仍可用（以前会永远返回空列表）
    final available = _voiceScanFailed ? <String>{} : _availableVoices;
    return voiceData
        .where((v) =>
            v.languageCode == _selectedLanguage && v.gender == _selectedGender)
        .where((v) => available.isEmpty || available.contains(v.value))
        .toList();
  }

  /// 下拉框实际使用的值。
  ///
  /// DropdownButton 要求 value 必须存在于 items 中，否则直接抛断言错误（红屏）。
  /// 这里做一次收敛：当前语音不在过滤结果里时返回 null（显示 hint）。
  String? get _voiceDropdownValue {
    final values = _filteredVoices.map((v) => v.value).toSet();
    return values.contains(_selectedVoice) ? _selectedVoice : null;
  }

  @override
  void initState() {
    super.initState();
    _scanVoices();
    _loadExportPath();
    _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state.playing;
      });
    });
    _positionSub = _audioPlayer.positionStream.listen((position) {
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
        _currentSentenceIndex = _sentenceIndexAt(position);
      });
    });
    _durationSub = _audioPlayer.durationStream.listen((duration) {
      if (!mounted || duration == null) return;
      setState(() {
        _totalDuration = duration;
      });
    });
  }

  /// 按播放位置定位当前句。
  int _sentenceIndexAt(Duration position) {
    final posMs = position.inMilliseconds;
    if (_sentenceAudioOffsetsMs.isEmpty) return 0;
    var index = 0;
    for (var i = 0; i < _sentenceAudioOffsetsMs.length; i++) {
      if (posMs >= _sentenceAudioOffsetsMs[i]) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _textController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  // ── sayit-poc 可执行文件定位 ──────────────────────────────────────────

  /// 所有可能的 sayit-poc 位置，按优先级排列。
  ///
  /// 以前每个平台只认一个写死路径，打包脚本放的位置一不一致就彻底找不到；
  /// 而且 CI 里 Windows 拷到 `Release/` 而 Dart 找 `Release/bin/`、
  /// Linux 拷到 `bundle/lib/` 而 Dart 找 `bundle/`，两个平台的发布包都是坏的。
  /// 这里把各平台可能的落点都列出来逐个探测。
  List<String> _pocBinaryCandidates() {
    if (Platform.isMacOS) {
      final base = File(Platform.resolvedExecutable).parent.parent.path;
      return [
        '$base/Resources/bin/sayit-poc',
        '$base/MacOS/sayit-poc',
        '$base/Frameworks/sayit-poc',
      ];
    } else if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return [
        '$exeDir\\bin\\sayit-poc.exe',
        '$exeDir\\sayit-poc.exe',
      ];
    } else {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return [
        '$exeDir/sayit-poc',
        '$exeDir/lib/sayit-poc',
        '$exeDir/bin/sayit-poc',
      ];
    }
  }

  String? _resolvePocBinary() {
    for (final candidate in _pocBinaryCandidates()) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  // ── 语音扫描 ──────────────────────────────────────────────────────────

  Future<void> _scanVoices() async {
    setState(() {
      _isScanningVoices = true;
      _statusMessage = '正在扫描可用语音...';
    });

    final pocBinary = _resolvePocBinary();
    if (pocBinary == null) {
      if (!mounted) return;
      setState(() {
        _isScanningVoices = false;
        _voiceScanFailed = true;
        _statusMessage = '未找到 sayit-poc（已查找：${_pocBinaryCandidates().join('、')}）';
      });
      return;
    }

    try {
      final result = await Process.run(pocBinary, ['--list-voices']);
      if (!mounted) return;

      // 以前只有 exitCode == 0 才更新状态：非零退出（例如 Python 装了但没装
      // edge_tts）时 _isScanningVoices 永远是 true，界面永久卡在"正在扫描"。
      if (result.exitCode == 0) {
        final decoded = jsonDecode(result.stdout as String);
        final available = (decoded as List)
            .map((v) => (v as Map)['short_name'] as String? ?? '')
            .where((s) => s.isNotEmpty)
            .toSet();
        setState(() {
          _availableVoices = available;
          _isScanningVoices = false;
          _voiceScanFailed = false;
          if (!_availableVoices.contains(_selectedVoice)) {
            final filtered = _filteredVoices;
            if (filtered.isNotEmpty) {
              _selectedVoice = filtered.first.value;
            }
          }
          _statusMessage = '已扫描 ${_availableVoices.length} 个可用语音';
        });
      } else {
        final detail = (result.stderr as String?)?.trim() ?? '';
        setState(() {
          _isScanningVoices = false;
          _voiceScanFailed = true;
          _statusMessage = '语音扫描失败（exit=${result.exitCode}）'
              '${detail.isNotEmpty ? '：$detail' : ''}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanningVoices = false;
        _voiceScanFailed = true;
        _statusMessage = '语音扫描失败：$e';
      });
    }
  }

  // ── 合成 ──────────────────────────────────────────────────────────────

  Future<SynthesisResult> _synthesizeText(String text, String voice,
      double speed, double pitch, double volume) async {
    final pocBinary = _resolvePocBinary();
    if (pocBinary == null) {
      throw Exception('未找到 sayit-poc 可执行文件');
    }
    if (voice.isEmpty) {
      throw Exception('当前语言/性别下没有可用语音，请换一个语言或性别');
    }

    final processedText = TextSegmenter.preprocessText(text);
    if (processedText.isEmpty) {
      throw Exception('待合成的文本为空');
    }
    final encodedText = base64Encode(utf8.encode(processedText));
    final ratePercent = ((speed - 1.0) * 100).round();
    final rate = ratePercent >= 0 ? '+$ratePercent%' : '$ratePercent%';
    final pitchHz = (pitch * 50).round();
    final pitchStr = pitchHz >= 0 ? '+${pitchHz}Hz' : '${pitchHz}Hz';
    final volumePercent = ((volume - 1.0) * 100).round();
    final volumeStr =
        volumePercent >= 0 ? '+$volumePercent%' : '$volumePercent%';

    final result = await Process.run(
      pocBinary,
      [
        '--synthesize-text=$encodedText',
        '--voice=$voice',
        '--rate=$rate',
        '--pitch=$pitchStr',
        '--volume=$volumeStr',
        '--ssml-base64',
      ],
    );

    if (result.exitCode != 0) {
      final err = (result.stderr as String?)?.trim() ?? '';
      throw Exception('合成失败（exit=${result.exitCode}）'
          '${err.isNotEmpty ? '：$err' : ''}');
    }

    final stdout = (result.stdout as String).trim();
    if (stdout.isEmpty) {
      throw Exception('合成失败：sayit-poc 没有输出');
    }

    final json = jsonDecode(stdout) as Map<String, dynamic>;

    final audioBase64 = json['audio_base64'] as String? ?? '';
    if (audioBase64.isEmpty) {
      throw Exception('合成失败：返回音频为空');
    }
    final audio = base64Decode(audioBase64);

    final boundaries = ((json['boundaries'] as List?) ?? const [])
        .map((b) => WordBoundary(
              textOffset: (b['text_offset'] as num?)?.toInt() ?? 0,
              textLength: (b['text_length'] as num?)?.toInt() ?? 0,
              audioOffsetMs: (b['audio_offset_ms'] as num?)?.toDouble() ?? 0.0,
              durationMs: (b['duration_ms'] as num?)?.toDouble() ?? 0.0,
              text: (b['text'] as String?) ?? '',
              boundaryType: (b['boundary_type'] as String?) ?? '',
            ))
        .toList();

    final format = (json['format'] as String?) ?? '';
    // edge_tts 的输出格式是**固定的**（audio-24khz-48kbitrate-mono-mp3），
    // 见 sayit-edge/src/lib.rs 的 EDGE_OUTPUT_FORMAT。这里只接受 mp3。
    if (format != 'mp3') {
      throw Exception('期望 MP3 输出（edge_tts 固定格式），实际得到 "$format"。'
          '请检查 sayit-poc 是否被旧版本覆盖。');
    }

    return SynthesisResult(
      audio: Uint8List.fromList(audio),
      sampleRate: (json['sample_rate'] as num?)?.toInt() ?? 24000,
      channels: (json['channels'] as num?)?.toInt() ?? 1,
      format: format,
      boundaries: boundaries,
    );
  }

  /// 逐句合成并把每段 MP3 字节拼成一整段。
  ///
  /// **不插入句间静音。** edge_tts 输出的是固定编码的 MP3
  /// （48 kbps CBR → 每秒恰好 6000 字节），要往里塞 N 毫秒静音，
  /// 得先解码成 PCM、拼完再编码回 MP3，而本项目没有内嵌 MP3 编码器；
  /// 硬拼无声帧又容易让解码器爆音。所以直接拼接，
  /// 句间停顿完全交给 TTS 自己处理（"。"、"!"、"?" 之后 edge_tts 会自然停一拍）。
  Future<_MixedAudio> _mixSentences(
    List<Sentence> sentences, {
    String progressPrefix = '正在合成',
  }) async {
    final bytes = BytesBuilder(copy: false);
    final offsets = <int>[];

    for (var i = 0; i < sentences.length; i++) {
      if (!mounted) throw const _CancelledException();
      setState(() {
        _statusMessage = '$progressPrefix第 ${i + 1}/${sentences.length} 句';
      });

      final sentence = sentences[i];
      final result = await _synthesizeText(
          sentence.text, _selectedVoice, _speed, _pitch, _volume);

      // 起始时间 = 已写入字节数换算出的毫秒（CBR 字节→毫秒是精确的）。
      // 以前用「最后一条 boundary 的结束时间」累加，忽略了每句开头的静音/前导，
      // 句数一多高亮就越来越滞后。
      offsets.add(_bytesToMs(bytes.length));
      bytes.add(result.audio);
    }

    return _MixedAudio(
      bytes: Uint8List.fromList(bytes.takeBytes()),
      sentenceOffsetsMs: offsets,
    );
  }

  /// 把 MP3 字节数换算成毫秒。edge_tts 的输出是 48 kbps CBR（6000 字节/秒），
  /// 这是固定常量，所以这里没有"采样率/声道"参数。
  static int _bytesToMs(int bytes) {
    return (bytes * 1000 / _kBytesPerMs).round();
  }

  // ── 分句 / 播放 ───────────────────────────────────────────────────────

  void _segmentText() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _sentences = [];
        _currentSentenceIndex = -1;
        _statusMessage = '请输入文本';
      });
      return;
    }

    setState(() {
      _sentences = _segmenter.segment(text);
      _currentSentenceIndex = -1;
      _statusMessage = '分句完成：${_sentences.length} 句';
    });
  }

  Future<void> _generateAndPlay() async {
    if (_isGenerating) return;

    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _sentences = [];
        _currentSentenceIndex = -1;
        _statusMessage = '请输入文本';
      });
      return;
    }

    _segmentText();
    if (_sentences.isEmpty) return;

    setState(() {
      _isGenerating = true;
      _statusMessage = '正在生成...';
    });

    try {
      final mixed = await _mixSentences(_sentences);
      if (!mounted) return;

      _sentenceAudioOffsetsMs = mixed.sentenceOffsetsMs;
      await _audioPlayer.setAudioSource(
        _BytesAudioSource(mixed.bytes),
      );

      if (!mounted) return;
      setState(() {
        _currentSentenceIndex = 0;
        _statusMessage = '播放中';
      });

      await _audioPlayer.play();
    } on _CancelledException {
      // 界面已销毁，忽略
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = '错误：$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _togglePause() async {
    // 播放结束后再点"继续"：直接 play() 不会重播，需要先回到开头
    if (!_isPlaying &&
        _audioPlayer.processingState == ProcessingState.completed) {
      await _audioPlayer.seek(Duration.zero);
    }
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  // ── 导出 ──────────────────────────────────────────────────────────────

  Future<void> _exportAudio() async {
    // 以前没有保护，可以并发点两次导出，写两遍（第二次还会覆盖第一次）
    if (_isExporting || _isGenerating) return;

    if (_sentences.isEmpty) {
      _segmentText();
      if (_sentences.isEmpty) return;
    }

    setState(() {
      _isExporting = true;
      _statusMessage = '正在导出...';
    });

    try {
      final sentences = List<Sentence>.from(_sentences);
      final mixed = await _mixSentences(sentences, progressPrefix: '正在导出');
      if (!mounted) return;

      final mp3Bytes = mixed.bytes;

      final basePath =
          _exportPath ?? (await getApplicationDocumentsDirectory()).path;
      final dir = Directory(basePath);

      var nextNum = 1;
      if (await dir.exists()) {
        final files = await dir.list().toList();
        final pattern = RegExp(r'^(\d+)_');
        for (final file in files) {
          if (file is! File) continue;
          if (!file.path.toLowerCase().endsWith('.$_kAudioExtension')) continue;
          // 不能只按 '/' 切：Windows 的路径分隔符是 '\'，那样永远取不到文件名，
          // nextNum 恒为 1，第二次导出会静默覆盖第一次的文件。
          final match = pattern.firstMatch(_basename(file.path));
          if (match != null) {
            final num = int.tryParse(match.group(1)!);
            if (num != null && num >= nextNum) {
              nextNum = num + 1;
            }
          }
        }
      } else {
        await dir.create(recursive: true);
      }

      final runes = sentences.first.text.runes.toList();
      var prefix = String.fromCharCodes(runes.take(10).toList())
          .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
          .trim();
      if (prefix.isEmpty) prefix = 'sayit';

      final filePath =
          '$basePath${Platform.pathSeparator}${nextNum}_$prefix.$_kAudioExtension';
      await File(filePath).writeAsBytes(mp3Bytes);

      if (!mounted) return;
      setState(() {
        _statusMessage = '已导出：$filePath';
      });
    } on _CancelledException {
      // 界面已销毁，忽略
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = '导出错误：$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? normalized : normalized.substring(idx + 1);
  }

  // ── 导入 / 导出设定 ───────────────────────────────────────────────────

  Future<void> _importText() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );

    final path = result?.files.single.path;
    if (path == null) return;

    try {
      final bytes = await File(path).readAsBytes();
      String content;
      try {
        // 严格解码：UTF-8 非法字节会抛异常，而不是悄悄塞一堆 U+FFFD
        content = utf8.decode(bytes);
      } catch (_) {
        if (!mounted) return;
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('无法识别文本编码'),
            content: const Text(
                '该文件不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）。\n\n'
                '要按 Latin-1 强行读取吗？中文会显示为乱码。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'latin1'),
                child: const Text('按 Latin-1 读取'),
              ),
            ],
          ),
        );
        if (choice != 'latin1') return;
        content = latin1.decode(bytes);
      }

      // 去掉 UTF-8 BOM
      if (content.isNotEmpty && content.codeUnitAt(0) == 0xFEFF) {
        content = content.substring(1);
      }

      if (!mounted) return;
      setState(() {
        _textController.text = content;
      });
      _segmentText();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = '导入文本失败：$e';
      });
    }
  }

  Future<void> _importSettings() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result == null || result.files.single.path == null) return;

    try {
      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final settings = jsonDecode(content) as Map<String, dynamic>;

      final validLanguageCodes = languages.map((l) => l['code']!).toSet();
      final validGenders = {'female', 'male'};
      final validVoiceValues = voiceData.map((v) => v.value).toSet();

      final importedVoice = settings['voice'] as String?;
      final importedLanguage = settings['language'] as String?;
      final importedGender = settings['gender'] as String?;
      final importedSpeed = (settings['speed'] as num?)?.toDouble();
      final importedPitch = (settings['pitch'] as num?)?.toDouble();
      final importedVolume = (settings['volume'] as num?)?.toDouble();
      final importedExportPath = settings['exportPath'] as String?;

      String? finalExportPath = importedExportPath;
      if (importedExportPath != null) {
        final dir = Directory(importedExportPath);
        if (!await dir.exists()) {
          // 经过了 await，回到 UI 层前必须再判一次 mounted，
          // 否则用户切换页面后这里会拿一个已卸载的 BuildContext。
          if (!mounted) return;
          final create = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('文件夹不存在'),
              content:
                  Text('设定的保存位置 "$importedExportPath" 不存在。是否创建该文件夹？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('否'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('是'),
                ),
              ],
            ),
          );
          if (create == true) {
            await dir.create(recursive: true);
            finalExportPath = importedExportPath;
          } else {
            finalExportPath = await FilePicker.platform.getDirectoryPath(
              dialogTitle: '选择导出位置',
            );
          }
        }
      }

      // 持久化导出路径：用户显式清空时要 remove 旧值，
      // 否则界面显示"已清空"而下次启动又冒出旧路径。
      final prefs = await SharedPreferences.getInstance();
      if (finalExportPath != null && finalExportPath.isNotEmpty) {
        await prefs.setString(_kExportPathKey, finalExportPath);
      } else {
        await prefs.remove(_kExportPathKey);
      }

      if (!mounted) return;
      setState(() {
        // 语言 / 性别是独立字段，不能只在"语音合法"时才更新 ——
        // 以前它们被包在 `if (importedVoice != null && valid)` 里，
        // 只导语言/性别不导语音时会静默失效。
        if (importedLanguage != null &&
            validLanguageCodes.contains(importedLanguage)) {
          _selectedLanguage = importedLanguage;
        }
        if (importedGender != null && validGenders.contains(importedGender)) {
          _selectedGender = importedGender;
        }
        if (importedVoice != null && validVoiceValues.contains(importedVoice)) {
          _selectedVoice = importedVoice;
        }
        if (importedSpeed != null &&
            importedSpeed >= 0.5 &&
            importedSpeed <= 2.0) {
          _speed = importedSpeed;
        }
        if (importedPitch != null &&
            importedPitch >= -1.0 &&
            importedPitch <= 1.0) {
          _pitch = importedPitch;
        }
        if (importedVolume != null &&
            importedVolume >= 0.0 &&
            importedVolume <= 2.0) {
          _volume = importedVolume;
        }
        _exportPath =
            (finalExportPath != null && finalExportPath.isNotEmpty)
                ? finalExportPath
                : null;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设定已导入')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  Future<void> _selectExportPath() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出位置',
    );
    if (result == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kExportPathKey, result);
    if (mounted) {
      setState(() {
        _exportPath = result;
      });
    }
  }

  Future<void> _loadExportPath() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kExportPathKey);
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() {
        _exportPath = saved;
      });
    }
  }

  Future<void> _exportSettings() async {
    final settings = {
      'voice': _selectedVoice,
      'language': _selectedLanguage,
      'gender': _selectedGender,
      'speed': _speed,
      'pitch': _pitch,
      'volume': _volume,
      'exportPath': _exportPath,
    };

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final result = await FilePicker.platform.saveFile(
      dialogTitle: '导出设定',
      fileName: 'sayit_settings_$timestamp.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result != null) {
      await File(result).writeAsString(jsonEncode(settings));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设定已导出: $result')),
        );
      }
    }
  }

  // ── 对话框 ────────────────────────────────────────────────────────────

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用帮助'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('【文本输入】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('在文本框中输入或粘贴要朗读的文字，点击"分句"进行分段。'),
              SizedBox(height: 12),
              Text('【强调标记】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('用 [!文字!] 包裹需要强调的内容。标记会被自动去掉，只朗读内部文字。'),
              SizedBox(height: 12),
              Text('【语音设置】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('顶部可选择语言、性别和具体语音。下方的滑块可调节语速、音高和音量。'),
              SizedBox(height: 12),
              Text('【播放控制】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('点击"生成并播放"合成并播放语音。播放过程中可暂停、继续或停止。'),
              Text('句末标点决定句间停顿：。！？ 500ms，； 300ms，, . ; : 200ms。'),
              SizedBox(height: 12),
              Text('【导出音频】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('点击文件夹图标设置导出位置，然后点击"导出"保存为 WAV 文件。'),
              Text('文件名格式：序号_前10个字.wav'),
              Text('说明：为保证句间停顿与高亮时间轴精确，内部使用 24kHz 16bit 单声道 PCM，'
                  '因此导出为无损 WAV 而不是 MP3。'),
              SizedBox(height: 12),
              Text('【导入/导出设置】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('可保存当前语音设置为 JSON 文件，或从文件恢复设置。'),
              SizedBox(height: 12),
              Text('【运行环境】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('需要 Python 3.8+ 与 edge_tts：pip install edge_tts'),
              Text('可用 SAYIT_PYTHON 环境变量指定解释器路径。'),
              SizedBox(height: 12),
              Text('【CLI 命令】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('--list-voices：列出所有可用语音'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(_kAppNameZh),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 版本号来自 lib/src/build_info.dart（由 scripts/sync_version.py
            // 从仓库根的 VERSION 生成），不要在界面里硬编码。
            // 这里用英文名 + 版本，对话框标题用的是中文名，中英文名各出现一次。
            Text('$_kAppNameEn v$kAppVersion'),
            SizedBox(height: 8),
            Text('开发者: MagicianEW'),
            SizedBox(height: 16),
            Text('许可证: GPL-3.0-or-later'),
            SizedBox(height: 8),
            Text('本软件遵循 GPL-3.0-or-later 协议开源。'),
            SizedBox(height: 16),
            Text('项目页面: https://github.com/MagicianEW/SayIt'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ── 界面 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final totalMs = _totalDuration.inMilliseconds;
    final canSeek = _isPlaying || totalMs > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text(_kAppNameZh),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            onPressed: _importText,
            tooltip: '导入文本文件',
          ),
          IconButton(
            icon: const Icon(Icons.settings_backup_restore),
            onPressed: _importSettings,
            tooltip: '导入设定',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _exportSettings,
            tooltip: '导出设定',
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelp,
            tooltip: '帮助',
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showAbout,
            tooltip: '关于',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 用 Flexible 而不是裸 SingleChildScrollView：
            // Column 给子控件的高度约束是无界的，裸 ScrollView 会把内容撑到无限高，
            // 窗口变矮时就 RenderFlex overflowed。Flexible 让它在空间不足时收缩并可滚动。
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _textController,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '输入文本',
                        hintText: '在此输入或粘贴文本...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _segmentText,
                            icon: const Icon(Icons.segment),
                            label: const Text('分句'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: _isGenerating ? null : _generateAndPlay,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('生成并播放'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: _isGenerating ? null : _togglePause,
                            icon:
                                Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                            tooltip: _isPlaying ? '暂停' : '继续',
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: canSeek ? () => _audioPlayer.stop() : null,
                            icon: const Icon(Icons.stop),
                            tooltip: '停止',
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: _selectExportPath,
                            icon: const Icon(Icons.folder_open),
                            tooltip:
                                '保存位置${_exportPath != null ? ' ($_exportPath)' : ''}',
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: _isExporting ? null : _exportAudio,
                            icon: const Icon(Icons.save_alt),
                            label: const Text('导出'),
                          ),
                          const SizedBox(width: 16),
                          DropdownButton<String>(
                            value: _selectedLanguage,
                            items: languages
                                .map((l) => DropdownMenuItem(
                                      value: l['code'],
                                      child: Text(l['name']!,
                                          style: const TextStyle(fontSize: 12)),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _selectedLanguage = value;
                                _pickDefaultVoice();
                              });
                            },
                          ),
                          const SizedBox(width: 4),
                          DropdownButton<String>(
                            value: _selectedGender,
                            items: genders
                                .map((g) => DropdownMenuItem(
                                      value: g['code'],
                                      child: Text(g['name']!,
                                          style: const TextStyle(fontSize: 12)),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _selectedGender = value;
                                _pickDefaultVoice();
                              });
                            },
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 180,
                            child: DropdownButton<String>(
                              // 关键：value 必须存在于 items 中，否则 Flutter 直接抛断言错误。
                              // 过滤结果为空时传 null（显示 hint），不再沿用上一个语言的语音。
                              value: _voiceDropdownValue,
                              hint: const Text('无可用语音',
                                  style: TextStyle(fontSize: 12)),
                              isExpanded: true,
                              items: _filteredVoices
                                  .map((v) => DropdownMenuItem(
                                        value: v.value,
                                        child: Text(v.name,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 12)),
                                      ))
                                  .toList(),
                              onChanged: _filteredVoices.isEmpty
                                  ? null
                                  : (value) {
                                      if (value == null) return;
                                      setState(() => _selectedVoice = value);
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (canSeek)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          height: 40,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 70,
                                child: Text(_formatDuration(_currentPosition)),
                              ),
                              Expanded(
                                child: Slider(
                                  value: totalMs > 0
                                      ? _currentPosition.inMilliseconds
                                          .toDouble()
                                          .clamp(0.0, totalMs.toDouble())
                                          .toDouble()
                                      : 0.0,
                                  min: 0,
                                  max: totalMs > 0 ? totalMs.toDouble() : 1.0,
                                  onChanged: (value) {
                                    _audioPlayer.seek(
                                        Duration(milliseconds: value.round()));
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 70,
                                child: Text(_formatDuration(_totalDuration)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('语速'),
                        Expanded(
                          child: Slider(
                            value: _speed,
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            label: '${(_speed * 100).round()}%',
                            onChanged: (value) {
                              setState(() {
                                _speed = value;
                              });
                            },
                          ),
                        ),
                        Text('${(_speed * 100).round()}%'),
                      ],
                    ),
                    Row(
                      children: [
                        const Text('音高'),
                        Expanded(
                          child: Slider(
                            value: _pitch,
                            min: -1.0,
                            max: 1.0,
                            divisions: 20,
                            label: _pitch >= 0
                                ? '+${(_pitch * 50).round()}Hz'
                                : '${(_pitch * 50).round()}Hz',
                            onChanged: (value) {
                              setState(() {
                                _pitch = value;
                              });
                            },
                          ),
                        ),
                        Text(_pitch >= 0
                            ? '+${(_pitch * 50).round()}Hz'
                            : '${(_pitch * 50).round()}Hz'),
                      ],
                    ),
                    Row(
                      children: [
                        const Text('音量'),
                        Expanded(
                          child: Slider(
                            value: _volume,
                            min: 0.0,
                            max: 2.0,
                            divisions: 20,
                            label: '${(_volume * 100).round()}%',
                            onChanged: (value) {
                              setState(() {
                                _volume = value;
                              });
                            },
                          ),
                        ),
                        Text('${(_volume * 100).round()}%'),
                      ],
                    ),
                    if (_statusMessage != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: SelectableText(_statusMessage!),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_sentences.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: _sentences.length,
                  itemBuilder: (context, index) {
                    final sentence = _sentences[index];
                    final isActive = index == _currentSentenceIndex;

                    return GestureDetector(
                      onTap: () async {
                        setState(() => _currentSentenceIndex = index);
                        try {
                          final result = await _synthesizeText(sentence.text,
                              _selectedVoice, _speed, _pitch, _volume);
                          await _audioPlayer.setAudioSource(
                            _BytesAudioSource(result.audio),
                          );
                          await _audioPlayer.play();
                        } catch (e) {
                          if (!mounted) return;
                          setState(() {
                            _statusMessage = '试听失败：$e';
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color:
                              isActive ? Colors.indigo[100] : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          border: isActive
                              ? Border.all(color: Colors.indigo)
                              : null,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 30,
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: isActive ? Colors.indigo : Colors.grey,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                sentence.text,
                                style: TextStyle(
                                  fontSize: 16,
                                  backgroundColor:
                                      isActive ? Colors.indigo[50] : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 语言/性别变化后挑一个合法语音；没有可用项时置空（由下拉框显示 hint）。
  void _pickDefaultVoice() {
    final filtered = _filteredVoices;
    _selectedVoice = filtered.isNotEmpty ? filtered.first.value : '';
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    // 以前没有小时位，超过 1 小时的音频会把 1:05:30 显示成 05:30
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _BytesAudioSource extends StreamAudioSource {
  final Uint8List _bytes;

  /// edge_tts 输出的就是 MP3，所以 contentType 恒为 audio/mpeg，
  /// 直接 hardcode 即可，调用方不必关心。
  _BytesAudioSource(this._bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    var from = start ?? 0;
    var to = end ?? _bytes.length;
    if (from < 0) from = 0;
    if (to > _bytes.length) to = _bytes.length;
    if (to < from) to = from;

    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(_bytes.sublist(from, to)),
      contentType: 'audio/mpeg',
    );
  }
}
