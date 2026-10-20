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
import 'src/text_decoder.dart';
import 'src/text_segmenter.dart';
import 'src/tts_error.dart';
import 'src/ui_panels.dart';
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
const _kVoiceKey = 'sayit_voice';
const _kLanguageKey = 'sayit_language';
const _kGenderKey = 'sayit_gender';
const _kSpeedKey = 'sayit_speed';
const _kPitchKey = 'sayit_pitch';
const _kVolumeKey = 'sayit_volume';

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

/// 48 kbps CBR → 6000 字节/秒。逐句高亮的时间轴按**已写入字节数**换算，
/// 而不是靠边界事件累加（那样会随句数累积滞后）。
///
/// 注意这只是**近似**，不是帧级精确：拼接的每段 MP3 各自带帧头与编码器延迟信息，
/// 字节换算出的时间与解码器上报的时长（just_audio 的 duration）可能存在偏差，
/// 长文本尾部的高亮会有肉眼可见的偏移。
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
    final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    return MaterialApp(
      title: _kAppNameZh,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        // 桌面端信息密度高一点，按钮/输入框别太占地方。
        visualDensity: VisualDensity.compact,
        // 滚动条统一成细条。界面上只有输入框和下方的音频列表会滚动，
        // 样式统一后不容易误以为滑块区也在滚动。
        scrollbarTheme: ScrollbarThemeData(
          thickness: const WidgetStatePropertyAll(6),
          radius: const Radius.circular(3),
          thumbVisibility: const WidgetStatePropertyAll(false),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
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
  });}

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
  /// 整段 MP3 字节（CBR 48kbps，每秒 6000 字节 → 时长 ≈ bytes / 6000 秒，
  /// 近似换算的偏差见 [`_kBytesPerMs`]）。
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

  /// 正在跑的那次 `sayit-poc` 子进程。
  ///
  /// 以前用 `Process.run`（阻塞等待），拿不到句柄，「停止」只能停播放器、
  /// 停不了正在进行的合成 —— 唯一能中断的时机是 `mounted == false`，
  /// 也就是只有关窗口才真的停得下来。改成 `Process.start` 后可以 kill。
  Process? _activePocProcess;

  /// 用户点了「停止」。`_mixSentences` 在每句开头检查它并抛
  /// [_CancelledException]，同时 [_activePocProcess] 会被 kill。
  bool _cancelRequested = false;

  /// 正在试听单句。
  ///
  /// 试听换的是单句音源，但 [_sentenceAudioOffsetsMs] 还是整篇的偏移表；
  /// 单句音频从 0ms 开始，`_sentenceIndexAt(0)` 恒返回 0，
  /// 于是 `positionStream` 会把高亮错拉到第 1 句。试听期间靠这个标志跳过
  /// 高亮更新。
  bool _isPreviewing = false;

  /// 试听令牌：连续快速点不同句子时，只有最后一次的结果会被播放。
  int _previewToken = 0;

  /// 本次导入设定时被拒绝的字段，用于如实告诉用户"这个没生效"，
  /// 而不是弹一句笼统的「设定已导入」就完事。
  final List<String> _voiceRejects = [];

  /// 延迟持久化设置的定时器。滑块 onChanged 每拖动一帧就触发一次，
  /// 直接落盘会把 SharedPreferences 写爆，所以合并成一次。
  Timer? _persistTimer;

  /// 已合成音频的缓存，供「导出」复用（见 [_mixedAudioFor]）。
  _MixedAudio? _cachedMixed;

  /// 缓存对应的输入指纹：音色 + 三个参数 + 每句文本。任一项变了缓存即失效。
  String? _cachedFingerprint;

  /// 音频文件列表的滚动控制器。
  ///
  /// 显式给一份，好让列表的滚动条由我们自己掌控（细条、只在滚动时出现），
  /// 也避免 `PrimaryScrollController` 抢走焦点。
  final _listScrollController = ScrollController();

  String _selectedVoice = 'zh-CN-XiaoxiaoNeural';
  String _selectedLanguage = 'zh-CN';
  String _selectedGender = 'female';
  double _speed = 1.0;
  double _pitch = 0.0;
  double _volume = 1.0;
  String? _exportPath;

  /// 载入中的设置。[_scanVoices] 要等它完成才能决定默认音色，
  /// 否则扫描回调会用「内置默认音色」覆盖掉刚读出来的用户设置。
  Future<void>? _settingsLoaded;

  static final _validLanguageCodes =
      languages.map((l) => l['code']!).toSet();
  static final _validGenders = {'female', 'male'};
  static final _voiceIndex = {for (final v in voiceData) v.value: v};
  static final _validVoiceValues = _voiceIndex.keys.toSet();

  List<VoiceInfo> get _filteredVoices {
    if (_isScanningVoices) return [];
    // 「扫描失败」和「扫描成功但返回 0 条」必须分开看：
    //
    // - 失败（含找不到 sayit-poc）：退回内置全量表，保证界面仍可用。
    // - 成功但 0 条：说明 edge_tts 环境本身坏了（没装 / 版本不兼容），
    //   此时把全量表摊开等于把一堆不可用的音色推给用户去挨个踩，
    //   所以同样按"不可用"处理，状态栏也要如实说明是 0 个而不是"已扫描 N 个"。
    final useFullTable = _voiceScanFailed || _availableVoices.isEmpty;
    return voiceData
        .where((v) =>
            v.languageCode == _selectedLanguage && v.gender == _selectedGender)
        .where((v) => useFullTable || _availableVoices.contains(v.value))
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

  /// 语言下拉实际使用的列表：**只列当前真的有可用音色的语言**。
  ///
  /// 内置音色表里约有三分之一（实测 131 条中 42 条）已经被 Edge 下线。
  /// 扫描成功后这些会被 [_filteredVoices] 过滤掉，于是某些语言会一个音色
  /// 都不剩 —— 用户在语言下拉里选得进去，却永远合不出声音。
  /// 实测受影响的组合有 7 个（zh-TW/男、en-AU/男、en-ZA/女、ar-SA/男女、
  /// da-DK/女、hi-IN/女），其中阿拉伯语整个语言都不可用。
  /// 所以语言列表要和音色一起收敛，不给用户选完就卡死的组合。
  List<Map<String, String>> get _availableLanguages {
    if (_isScanningVoices) return const [];
    final table = (_voiceScanFailed || _availableVoices.isEmpty)
        ? voiceData
        : voiceData.where((v) => _availableVoices.contains(v.value));
    final codes = table.map((v) => v.languageCode).toSet();
    return languages.where((l) => codes.contains(l['code'])).toList();
  }

  /// 性别下拉实际使用的列表：在**当前语言**下真的还有音色的性别。
  List<Map<String, String>> get _availableGenders {
    if (_isScanningVoices) return const [];
    final present = _filteredVoices.map((v) => v.gender).toSet();
    return genders.where((g) => present.contains(g['code'])).toList();
  }

  /// 收敛当前的语言 / 性别 / 音色，使三者自洽且当前真的有音色可用。
  ///
  /// 调用时机：语音扫描出结果之后、语言或性别下拉变更之后。
  void _reconcileSelection() {
    final langs = _availableLanguages;
    if (langs.isEmpty) return;

    if (!langs.any((l) => l['code'] == _selectedLanguage)) {
      _selectedLanguage = langs.first['code']!;
    }

    final gs = _availableGenders;
    if (gs.isNotEmpty && !gs.any((g) => g['code'] == _selectedGender)) {
      _selectedGender = gs.first['code']!;
    }

    // 只在当前音色真的不可用时才换。否则会把用户（从 SharedPreferences
    // 或设定文件）读回来的、仍然有效的音色又覆盖成列表里的第一个。
    final voices = _filteredVoices;
    if (voices.isNotEmpty && !voices.any((v) => v.value == _selectedVoice)) {
      _selectedVoice = voices.first.value;
    }
  }

  @override
  void initState() {
    super.initState();
    // 设置先起加载，扫描音色要等它完成（见 [_scanVoices]）
    _settingsLoaded = _loadSettings();
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
        // 试听单句时音源与整篇偏移表不匹配，跳过高亮更新，
        // 否则高亮会被 [_sentenceIndexAt] 拉到第 1 句。
        if (!_isPreviewing) {
          _currentSentenceIndex = _sentenceIndexAt(position);
        }
      });
    });
    _durationSub = _audioPlayer.durationStream.listen((duration) {
      if (!mounted || duration == null) return;
      setState(() {
        _totalDuration = duration;
      });
    });
  }

  /// 按播放位置定位当前句：找最后一个 offset ≤ posMs 的下标。
  ///
  /// 用二分而不是线性扫：`positionStream` 每个 tick 都会调这里，
  /// 长文本（几百句）线性扫是 O(n) × tick 数。
  int _sentenceIndexAt(Duration position) {
    final posMs = position.inMilliseconds;
    final offsets = _sentenceAudioOffsetsMs;
    if (offsets.isEmpty) return 0;
    var lo = 0;
    var hi = offsets.length - 1;
    var result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (offsets[mid] <= posMs) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _previewToken++;
    // 窗口关闭时如果还有合成在跑，别把它留成孤儿进程。
    _cancelRequested = true;
    _activePocProcess?.kill();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _textController.dispose();
    _listScrollController.dispose();
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
      // 先单独问一次环境。sayit-poc 以前在**每次**合成前都做同样的检查，
      // 而应用是逐句合成的 —— 于是一句文本要额外拉起 2 个 Python 进程
      // （查版本 + 查 edge_tts），20 句就是 40 次纯开销。
      // 这里改成启动时做一次，检查结果和提示文案都留给用户看。
      final env = await Process.run(pocBinary, ['--check-env']);
      if (!mounted) return;
      if (env.exitCode != 0) {
        final detail = (env.stderr as String?)?.trim() ?? '';
        if (detail.isNotEmpty) {
          setState(() {
            _isScanningVoices = false;
            _voiceScanFailed = true;
            _statusMessage = '运行环境有问题：${sanitizeTtsError(detail)}';
          });
          return;
        }
      }

      final result = await Process.run(pocBinary, ['--list-voices']);
      if (!mounted) return;

      // 等设置读盘完成再决定默认音色，否则这里的修正会把用户存下来的
      // 音色又覆盖回内置默认值。
      await _settingsLoaded;
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
          // 「扫描成功但一条都没有」和「扫描失败」要分开：
          // 前者说明 edge_tts 环境本身坏了，界面不能装作扫到了东西，
          // 状态栏必须如实说 0 个，并退回内置表让界面还能用。
          _voiceScanFailed = available.isEmpty;
          // 语言 / 性别 / 音色三者一起收敛：既要音色在扫描结果里，
          // 也要通过当前语言+性别的筛选，否则会出现"语言显示日语、
          // 音色却是中文"的错位。
          _reconcileSelection();
          _statusMessage = available.isEmpty
              ? '扫描到 0 个可用语音：edge_tts 可能未安装或版本不兼容，'
                  '已退回内置音色表'
              : '已扫描 ${available.length} 个可用语音';
        });
      } else {
        final detail = (result.stderr as String?)?.trim() ?? '';
        setState(() {
          _isScanningVoices = false;
          _voiceScanFailed = true;
          _statusMessage = '语音扫描失败（exit=${result.exitCode}）'
              '${detail.isNotEmpty ? '：${sanitizeTtsError(detail)}' : ''}';
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

    // 用 Process.start 而不是 Process.run：要留住句柄，「停止」才能 kill。
    // 以前是 Process.run（阻塞等待、拿不到句柄），合成过程中按「停止」毫无反应。
    final process = await Process.start(
      pocBinary,
      [
        '--synthesize-text=$encodedText',
        '--voice=$voice',
        '--rate=$rate',
        '--pitch=$pitchStr',
        '--volume=$volumeStr',
        '--text-base64',
      ],
    );
    _activePocProcess = process;

    final String stdout;
    final String stderr;
    final int exitCode;
    try {
      // stdout 装的是整段音频的 base64，量很大。必须和 exitCode 并行收，
      // 先 await exitCode 的话管道会被写满、子进程卡住不死锁。
      final outFuture = process.stdout.transform(utf8.decoder).join();
      final errFuture = process.stderr.transform(utf8.decoder).join();
      exitCode = await process.exitCode;
      stdout = await outFuture;
      stderr = await errFuture;
    } finally {
      _activePocProcess = null;
    }

    // 被「停止」kill 掉的子进程退出码是 -9，别当成合成失败报给用户。
    if (_cancelRequested) {
      throw const _CancelledException();
    }

    if (exitCode != 0) {
      // 原样抛会把 edge_tts 的完整请求 URL（含 DRM 令牌）带进状态栏 ——
      // 实测一次 403 的原始报错 397 字符里 362 个是用户用不上的 URL。
      throw Exception(sanitizeTtsError(stderr));
    }

    final out = stdout.trim();
    if (out.isEmpty) {
      throw Exception('合成失败：sayit-poc 没有输出');
    }

    final json = jsonDecode(out) as Map<String, dynamic>;

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
      // 用户按了「停止」：别再发起下一句的子进程。
      if (_cancelRequested) throw const _CancelledException();
      setState(() {
        _statusMessage = '$progressPrefix第 ${i + 1}/${sentences.length} 句';
      });

      final sentence = sentences[i];
      final result = await _synthesizeText(
          sentence.text, _selectedVoice, _speed, _pitch, _volume);

      // 起始时间 = 已写入字节数换算出的毫秒（近似，偏差见 _kBytesPerMs 的说明）。
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

  /// 合成结果的输入指纹：音色 + 三个参数 + 每句文本。
  /// 用来判断缓存的 [_cachedMixed] 还能不能用。
  String _synthFingerprint(List<Sentence> sentences) {
    return [
      _selectedVoice,
      _speed,
      _pitch,
      _volume,
      for (final s in sentences) s.text,
    ].join('\u0000');
  }

  /// 带缓存的 [_mixSentences]。
  ///
  /// 以前「导出」会无条件把整篇重新合成一遍 —— 用户先「生成并播放」再
  /// 「导出」，同样的文本就被完整合成两次，每遍都是 N 次网络请求。
  /// 这里按输入指纹缓存一份，参数或文本一变就自动失效。
  Future<_MixedAudio> _mixedAudioFor(
    List<Sentence> sentences, {
    String progressPrefix = '正在合成',
  }) async {
    final fingerprint = _synthFingerprint(sentences);
    final cached = _cachedMixed;
    if (_cachedFingerprint == fingerprint && cached != null) {
      if (mounted) {
        setState(() => _statusMessage = '复用已生成的音频，无需重新合成');
      }
      return cached;
    }

    final mixed = await _mixSentences(sentences, progressPrefix: progressPrefix);
    _cachedMixed = mixed;
    _cachedFingerprint = fingerprint;
    return mixed;
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
    _cancelRequested = false;

    try {
      // 开始新一轮合成前把旧音频停掉。以前是等新音源 setAudioSource 才换掉，
      // 结果合成全程旧音频还在放，听起来像"点了没反应"。
      await _audioPlayer.stop();

      final mixed = await _mixedAudioFor(_sentences);
      if (!mounted) return;
      if (_cancelRequested) throw const _CancelledException();

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
      if (mounted) {
        setState(() => _statusMessage = '已取消合成');
      }
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

  /// 「停止」：既要停播放，也要中断正在进行的合成。
  ///
  /// 以前只停播放器 —— 合成跑在 `Process.run` 里，拿不到句柄，
  /// 用户按停止毫无反应，只能干等整篇合成完（或者关窗口）。
  Future<void> _stop() async {
    if (_isGenerating || _isExporting) {
      _cancelRequested = true;
      // kill 掉当前那一个 sayit-poc；循环会在下一句开头发现标志并退出。
      _activePocProcess?.kill();
      if (mounted) {
        setState(() => _statusMessage = '正在取消...');
      }
    }
    // 试听/播放的进度：让待播的试听结果作废
    _previewToken++;
    await _audioPlayer.stop();
    if (mounted) {
      setState(() {
        _currentSentenceIndex = -1;
        _isPreviewing = false;
        if (!_isGenerating && !_isExporting) {
          _statusMessage = '已停止';
        }
      });
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
    _cancelRequested = false;

    try {
      final sentences = List<Sentence>.from(_sentences);
      // 走带缓存的版本：刚「生成并播放」完就点导出时，直接复用那份音频，
      // 不再把整篇重新合成一遍（每遍都是 N 次网络请求）。
      final mixed = await _mixedAudioFor(sentences, progressPrefix: '正在导出');
      if (!mounted) return;
      if (_cancelRequested) throw const _CancelledException();

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
      if (mounted) {
        setState(() => _statusMessage = '已取消导出');
      }
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

      // UTF-8 / UTF-16 / GB18030 依次自动识别（见 src/text_decoder.dart）。
      // 以前这里只有 UTF-8 成功或失败两条路，失败就只剩 Latin-1 兜底 ——
      // 而 Latin-1 对 GBK 是按字节一对一映射，中文必然变乱码，
      // 等于中文用户根本没法导入 txt。现在 GB18030 能自动读进来。
      final auto = tryDecodeText(bytes);
      late final String content;
      if (auto != null) {
        content = auto.text;
        // 上面刚 await 过 readAsBytes，界面可能已经销毁 —— setState 前必须判
        if (!mounted) return;
        if (auto.encoding != 'UTF-8') {
          setState(() => _statusMessage = '已按 ${auto.encoding} 解码该文件');
        }
      } else {
        // 两种都解不了（或 GB18030 解出来明显不像文字）——弹窗让用户选。
        if (!mounted) return;
        final gbBytes = tryDecodeGb18030(bytes);
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('无法自动识别文本编码'),
            content: Text(
                '这个文件既不是 UTF-8，${gbBytes != null ? '按 GB18030 解出来也不像正常文字' : 'GB18030 也解不了'}。\n\n'
                '如果是中文 Windows 导出的旧文件，可以按 GB18030 读取；'
                '如果是西欧语言的旧文件（如 Windows-1252），选 Latin-1。\n'
                '都不对的话，建议用编辑器另存为 UTF-8 再导入。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('取消'),
              ),
              if (gbBytes != null)
                TextButton(
                  onPressed: () => Navigator.pop(context, 'gb18030'),
                  child: const Text('按 GB18030 读取'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'latin1'),
                child: const Text('按 Latin-1 读取'),
              ),
            ],
          ),
        );
        if (choice == null || choice == 'cancel') return;
        content = choice == 'gb18030'
            ? (gbBytes ?? '')
            : latin1.decode(bytes);
        if (mounted) {
          setState(() => _statusMessage = '已按 $choice 解码该文件');
        }
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

      // 音色与语言/性别必须自洽。设定文件里三个字段是平级的，以前各自
      // 校验后独立写入，于是一份 "voice=中文音色 + language=日语" 的文件
      // 导入后：语言下拉显示日语、音色下拉显示"无可用语音"，但合成照常用
      // 那个中文音色去读日语文本 —— 界面和实际行为对不上。
      //
      // 这里以音色为准反推语言/性别（音色是唯一真正决定声音的字段），
      // 只有音色缺失或非法时才退回文件里写明的语言/性别。
      final matched =
          importedVoice == null ? null : _voiceIndex[importedVoice];
      final wantLanguage = matched?.languageCode ?? importedLanguage;
      final wantGender = matched?.gender ?? importedGender;

      setState(() {
        // 语言 / 性别是独立字段，不能只在"音色合法"时才更新 ——
        // 以前它们被包在 `if (importedVoice != null && valid)` 里，
        // 只导语言/性别不导音色时会静默失效。
        if (wantLanguage != null && validLanguageCodes.contains(wantLanguage)) {
          _selectedLanguage = wantLanguage;
        }
        if (wantGender != null && validGenders.contains(wantGender)) {
          _selectedGender = wantGender;
        }
        if (matched != null) {
          _selectedVoice = matched.value;
        } else if (importedVoice != null) {
          // 文件里的音色已经不在内置表里（多半是被 Edge 下线了）
          _voiceRejects.add(importedVoice);
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
        // 设定文件没带音色（或带了个已下线的）时，语言/性别可能变了而音色没变，
        // 那样又是"语言显示日语、音色是中文"的错位。这里统一收敛一次。
        _reconcileSelection();
      });

      // 导入完立刻落盘，省得用户下次启动还得重新导一次
      _schedulePersist();

      if (!mounted) return;
      // 如实说明哪些字段没生效，而不是一律报「设定已导入」
      final notes = <String>[];
      if (_voiceRejects.isNotEmpty) {
        notes.add('音色 ${_voiceRejects.join('、')} 不在当前音色表里（可能已被 Edge 下线），已忽略');
      }
      final swapped = matched != null &&
          ((importedLanguage != null && importedLanguage != matched.languageCode) ||
              (importedGender != null && importedGender != matched.gender));
      if (swapped) {
        notes.add('文件里的语言/性别与音色不一致，已按音色修正');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            notes.isEmpty ? '设定已导入' : '设定已导入，但有调整：${notes.join('；')}',
          ),
          duration: notes.isEmpty
              ? const Duration(seconds: 2)
              : const Duration(seconds: 6),
        ),
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

  /// 读回上次的音色 / 语言 / 性别 / 语速 / 音高 / 音量。
  ///
  /// 以前这些只在内存里，退出即丢，用户每次重启都要重设语速和音色
  /// （明明「导出设定」就能存，偏要手动走文件）。这里和导出路径一样落盘。
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // SharedPreferences 里可能被外部改坏（手改文件、旧版本遗留），
    // 每一项都要重新校验范围，不能直接信。
    double? clampNum(num? v, double min, double max, double fallback) {
      if (v == null) return fallback;
      final d = v.toDouble();
      if (d.isNaN || d < min || d > max) return fallback;
      return d;
    }

    setState(() {
      final lang = prefs.getString(_kLanguageKey);
      if (lang != null && _validLanguageCodes.contains(lang)) {
        _selectedLanguage = lang;
      }
      final gender = prefs.getString(_kGenderKey);
      if (gender != null && _validGenders.contains(gender)) {
        _selectedGender = gender;
      }
      final voice = prefs.getString(_kVoiceKey);
      if (voice != null && _validVoiceValues.contains(voice)) {
        _selectedVoice = voice;
      }
      _speed = clampNum(prefs.getDouble(_kSpeedKey), 0.5, 2.0, 1.0)!;
      _pitch = clampNum(prefs.getDouble(_kPitchKey), -1.0, 1.0, 0.0)!;
      _volume = clampNum(prefs.getDouble(_kVolumeKey), 0.0, 2.0, 1.0)!;
    });
  }

  /// 合并连续改动后再落盘。
  ///
  /// 三个滑块的 onChanged 每拖动一帧就触发，直接写 SharedPreferences
  /// 会在一次拖动里写几百次。
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _persistSettings();
    });
  }

  Future<void> _persistSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kVoiceKey, _selectedVoice);
    await prefs.setString(_kLanguageKey, _selectedLanguage);
    await prefs.setString(_kGenderKey, _selectedGender);
    await prefs.setDouble(_kSpeedKey, _speed);
    await prefs.setDouble(_kPitchKey, _pitch);
    await prefs.setDouble(_kVolumeKey, _volume);
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
              Text('也可以从工具栏的文件夹图标导入 .txt 文件；'
                  'UTF-8、UTF-16、GB18030（中文 Windows 导出的旧文件）'
                  '都能自动识别。'),
              SizedBox(height: 12),
              Text('【强调标记】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('用 [!文字!] 包裹需要强调的内容。标记会被自动去掉，只朗读内部文字。'),
              SizedBox(height: 12),
              Text('【语音设置】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('顶部可选择语言、性别和具体语音。下方的滑块可调节语速、音高和音量。'),
              SizedBox(height: 12),
              Text('【播放控制】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('点击"生成并播放"合成并播放语音。播放过程中可暂停、继续或停止；'
                  '正在合成时按"停止"会中断本次合成。'),
              Text('点击列表中的任意一句可单独试听该句。'),
              SizedBox(height: 12),
              Text('【导出音频】', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('点击文件夹图标设置导出位置，然后点击"导出"保存为 MP3 文件。'),
              Text('文件名格式：序号_前10个字.mp3'),
              Text('说明：edge_tts 的输出格式固定为 MP3（24kHz / 48kbps / 单声道），'
                  '应用无法更改。句与句之间不插入静音，'
                  '句间停顿由 TTS 在句末标点后自然处理。'),
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
    // 合成/导出过程中「停止」也必须可点：以前它只连着播放器，
    // 合成时按下去毫无反应，界面看着像卡死。
    final busy = _isGenerating || _isExporting;
    final canStop = busy || _isPlaying || totalMs > 0;

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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 文本输入 ────────────────────────────────────────────────
            // 超出 maxLines 后输入框自己内部滚动，滚动条落在输入框里。
            SectionPanel(
              icon: Icons.edit_note,
              title: '文本输入',
              trailing: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (context, value, _) => Text(
                  '${value.text.runes.length} 字',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              child: TextField(
                controller: _textController,
                minLines: 2,
                maxLines: 5,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '在此输入或粘贴文本…',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: _inputBorder(Theme.of(context)),
                  enabledBorder: _inputBorder(Theme.of(context)),
                  focusedBorder: _inputBorder(Theme.of(context), focused: true),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // ── 操作与参数 ──────────────────────────────────────────────
            // 这一整块**没有**外层滚动容器。
            // 滑块一旦落在纵向 ScrollView 里，拖动时会跟外层滚动抢手势，
            // 窗口变矮时还会冒出一条常驻滚动条 —— 界面里只保留
            // 「输入框」和「下方列表」两处滚动。
            SectionPanel(
              icon: Icons.tune,
              title: '操作与参数',
              trailing: busy
                  ? StatusPill(
                      icon: Icons.autorenew,
                      label: _isExporting ? '导出中…' : '合成中…',
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _segmentText,
                        icon: const Icon(Icons.segment, size: 18),
                        label: const Text('分句'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _isGenerating ? null : _generateAndPlay,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('生成并播放'),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: _isGenerating ? null : _togglePause,
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        tooltip: _isPlaying ? '暂停' : '继续',
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: canStop ? _stop : null,
                        icon: const Icon(Icons.stop),
                        tooltip: busy ? '取消合成' : '停止',
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: _selectExportPath,
                        icon: const Icon(Icons.folder_open),
                        tooltip:
                            '保存位置${_exportPath != null ? ' ($_exportPath)' : ''}',
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _isExporting ? null : _exportAudio,
                        icon: const Icon(Icons.save_alt, size: 18),
                        label: const Text('导出'),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // 语言/性别下拉都按"当前真的有可用音色"收敛。
                  // 只列有音色的语言/性别，用户才不会选到一个永远
                  // 合成不出来的组合（内置表里约三分之一音色已被
                  // Edge 下线，不收敛的话阿拉伯语整个语言都是死的）。
                  Row(
                    children: [
                      StyledDropdown<String>(
                        value: _availableLanguages
                                .any((l) => l['code'] == _selectedLanguage)
                            ? _selectedLanguage
                            : null,
                        hint: '无可用语言',
                        width: 150,
                        items: _availableLanguages
                            .map((l) => DropdownMenuItem(
                                  value: l['code'],
                                  child: Text(
                                    l['name']!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: _availableLanguages.isEmpty
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  _selectedLanguage = value;
                                  _reconcileSelection();
                                });
                                _schedulePersist();
                              },
                      ),
                      const SizedBox(width: 10),
                      StyledDropdown<String>(
                        value: _availableGenders
                                .any((g) => g['code'] == _selectedGender)
                            ? _selectedGender
                            : null,
                        hint: '无可用性别',
                        width: 120,
                        items: _availableGenders
                            .map((g) => DropdownMenuItem(
                                  value: g['code'],
                                  child: Text(
                                    g['name']!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: _availableGenders.isEmpty
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  _selectedGender = value;
                                  _pickDefaultVoice();
                                });
                                _schedulePersist();
                              },
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        // 关键：value 必须存在于 items 中，否则 Flutter 直接抛断言错误。
                        // 过滤结果为空时传 null（显示 hint），不再沿用上一个语言的语音。
                        child: StyledDropdown<String>(
                          value: _voiceDropdownValue,
                          hint: '无可用语音',
                          items: _filteredVoices
                              .map((v) => DropdownMenuItem(
                                    value: v.value,
                                    child: Text(
                                      v.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: _filteredVoices.isEmpty
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setState(() => _selectedVoice = value);
                                  _schedulePersist();
                                },
                        ),
                      ),
                    ],
                  ),
                  if (canStop) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          Icons.graphic_eq,
                          size: 14,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 56,
                          child: Text(
                            _formatDuration(_currentPosition),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              activeTrackColor:
                                  Theme.of(context).colorScheme.primary,
                              inactiveTrackColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.16),
                              thumbColor: Theme.of(context).colorScheme.primary,
                              overlayColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12),
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
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
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(
                            _formatDuration(_totalDuration),
                            textAlign: TextAlign.right,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color:
                            Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Column(
                      children: [
                        LabeledSlider(
                          label: '语速',
                          icon: Icons.speed,
                          value: _speed,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          valueText: '${(_speed * 100).round()}%',
                          tooltipLabel: '${(_speed * 100).round()}%',
                          onChanged: (value) {
                            setState(() {
                              _speed = value;
                            });
                            // 拖动过程中每帧都会进来，合并后再落盘
                            _schedulePersist();
                          },
                        ),
                        LabeledSlider(
                          label: '音高',
                          icon: Icons.music_note,
                          value: _pitch,
                          min: -1.0,
                          max: 1.0,
                          divisions: 20,
                          valueText: _pitch >= 0
                              ? '+${(_pitch * 50).round()}Hz'
                              : '${(_pitch * 50).round()}Hz',
                          tooltipLabel: _pitch >= 0
                              ? '+${(_pitch * 50).round()}Hz'
                              : '${(_pitch * 50).round()}Hz',
                          onChanged: (value) {
                            setState(() {
                              _pitch = value;
                            });
                            // 拖动过程中每帧都会进来，合并后再落盘
                            _schedulePersist();
                          },
                        ),
                        LabeledSlider(
                          label: '音量',
                          icon: Icons.volume_up,
                          value: _volume,
                          min: 0.0,
                          max: 2.0,
                          divisions: 20,
                          valueText: '${(_volume * 100).round()}%',
                          tooltipLabel: '${(_volume * 100).round()}%',
                          onChanged: (value) {
                            setState(() {
                              _volume = value;
                            });
                            // 拖动过程中每帧都会进来，合并后再落盘
                            _schedulePersist();
                          },
                        ),
                      ],
                    ),
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 10),
                    StatusBanner(
                      message: _statusMessage!,
                      isError: _looksLikeError(_statusMessage!),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ── 音频文件列表 ────────────────────────────────────────────
            // 界面里第二处（也是唯一另一处）允许滚动的地方。
            Expanded(
              child: SectionPanel(
                icon: Icons.library_music,
                title: '音频文件列表',
                fill: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                trailing: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '${_sentences.length} 句',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                child: _sentences.isEmpty
                    ? const EmptyListHint(
                        message: '输入文本后点「分句」，这里会列出每一句。\n'
                            '点某一句可以单独试听。',
                      )
                    // 列表的滚动条由 Flutter 桌面端的默认 ScrollBehavior
                    // 自动套上（RawScrollbar），这里不要再包一层 Scrollbar，
                    // 否则会画出两条。
                    : ListView.builder(
                        controller: _listScrollController,
                        padding: const EdgeInsets.only(right: 10),
                        itemCount: _sentences.length,
                        itemBuilder: (context, index) {
                          final sentence = _sentences[index];
                          final isActive = index == _currentSentenceIndex;

                          return SentenceTile(
                            index: index,
                            text: sentence.text,
                            isActive: isActive,
                            onTap: () async {
                              // 合成/导出进行中不允许试听：试听会另起一个
                              // sayit-poc 并换掉播放器音源，把正在拼接的音频冲掉。
                              if (_isGenerating || _isExporting) return;
                              // 令牌：连续快速点不同句子时，只有最后一次的结果会被播放
                              final token = ++_previewToken;
                              setState(() => _currentSentenceIndex = index);
                              // 试听用的是单句音源，而 [_sentenceAudioOffsetsMs]
                              // 是整篇的偏移表；不置位的话 positionStream 会用整篇
                              // 偏移算高亮，单句音频从 0ms 开始 → 高亮被拉到第 1 句。
                              _isPreviewing = true;
                              try {
                                final result = await _synthesizeText(sentence.text,
                                    _selectedVoice, _speed, _pitch, _volume);
                                // 等待期间可能又点了别的句子，或开始了合成 → 丢弃本次结果
                                if (!mounted ||
                                    token != _previewToken ||
                                    _isGenerating ||
                                    _isExporting) {
                                  return;
                                }
                                await _audioPlayer.setAudioSource(
                                  _BytesAudioSource(result.audio),
                                );
                                await _audioPlayer.play();
                              } catch (e) {
                                if (!mounted) return;
                                setState(() {
                                  _statusMessage = '试听失败：$e';
                                });
                              } finally {
                                if (token == _previewToken) {
                                  _isPreviewing = false;
                                }
                              }
                            },
                          );
                        },
                      ),
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

  /// 状态文案是不是错误。带这些词就用红色的提示条显示。
  static bool _looksLikeError(String message) =>
      message.contains('错误') || message.contains('失败');
}

/// 输入框的边框：聚焦时换成主色，其余时候用一条淡描边。
OutlineInputBorder _inputBorder(
  ThemeData theme, {
  bool focused = false,
}) {
  final scheme = theme.colorScheme;
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(
      color: focused ? scheme.primary : scheme.outlineVariant,
      width: focused ? 1.5 : 1,
    ),
  );
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
