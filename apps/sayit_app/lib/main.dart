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
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'src/text_segmenter.dart';
import 'src/wav_concat.dart';
import 'src/voice_data.dart';

void main() {
  runApp(const SayItApp());
}

class SayItApp extends StatelessWidget {
  const SayItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '说吧',
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
  String? _statusMessage;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;

  String _selectedVoice = 'zh-CN-XiaoxiaoNeural';
  String _selectedLanguage = 'zh-CN';
  String _selectedGender = 'female';
  double _speed = 1.0;
  double _pitch = 0.0;
  double _volume = 1.0;

  List<VoiceInfo> get _filteredVoices {
    return voiceData.where((v) =>
      v.languageCode == _selectedLanguage && v.gender == _selectedGender
    ).toList();
  }

  @override
  void initState() {
    super.initState();
    _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state.playing;
      });
    });
    _positionSub = _audioPlayer.positionStream.listen((position) {
      if (!mounted) return;
      final posMs = position.inMilliseconds;
      int sentenceIndex = 0;
      for (int i = 0; i < _sentenceAudioOffsetsMs.length; i++) {
        final offset = _sentenceAudioOffsetsMs[i];
        final end = i < _sentenceAudioOffsetsMs.length - 1
            ? _sentenceAudioOffsetsMs[i + 1]
            : double.infinity;
        if (posMs >= offset && posMs < end) {
          sentenceIndex = i;
          break;
        }
      }
      setState(() {
        _currentPosition = position;
        _currentSentenceIndex = sentenceIndex;
      });
    });
    _durationSub = _audioPlayer.durationStream.listen((duration) {
      if (!mounted || duration == null) return;
      setState(() {
        _totalDuration = duration;
      });
    });
  }

  @override
  @override
  void dispose() {
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _textController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _segmentText() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _sentences = [];
        _statusMessage = '请输入文本';
      });
      return;
    }

    setState(() {
      _sentences = _segmenter.segment(text);
      _statusMessage = '分句完成：${_sentences.length} 句';
    });
  }

  Future<SynthesisResult> _synthesizeText(String text, String voice, double speed, double pitch, double volume) async {
    String pocBinary;
    if (Platform.isMacOS) {
      final appDir = File(Platform.resolvedExecutable).parent.parent;
      pocBinary = '${appDir.path}/Resources/bin/sayit-poc';
    } else if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      pocBinary = '$exeDir/bin/sayit-poc.exe';
    } else {
      throw Exception('Unsupported platform: ${Platform.operatingSystem}');
    }
    final processedText = TextSegmenter.preprocessText(text);
    final ratePercent = ((speed - 1.0) * 100).round();
    final rate = ratePercent >= 0 ? '+$ratePercent%' : '$ratePercent%';
    final pitchHz = (pitch * 50).round();
    final pitchStr = pitchHz >= 0 ? '+${pitchHz}Hz' : '${pitchHz}Hz';
    final volumePercent = ((volume - 1.0) * 100).round();
    final volumeStr = volumePercent >= 0 ? '+$volumePercent%' : '$volumePercent%';

    final result = await Process.run(
      pocBinary,
      ['--synthesize-text=$processedText', '--voice=$voice', '--rate=$rate', '--pitch=$pitchStr', '--volume=$volumeStr'],
    );

    if (result.exitCode != 0) {
      throw Exception('Synthesis failed: ${result.stderr}');
    }

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;

    final audioBase64 = json['audio_base64'] as String;
    final audio = base64Decode(audioBase64);

    final boundaries = (json['boundaries'] as List)
        .map((b) => WordBoundary(
              textOffset: b['text_offset'] as int,
              textLength: b['text_length'] as int,
              audioOffsetMs: (b['audio_offset_ms'] as num).toDouble(),
              durationMs: (b['duration_ms'] as num).toDouble(),
              text: b['text'] as String,
              boundaryType: b['boundary_type'] as String,
            ))
        .toList();

    return SynthesisResult(
      audio: Uint8List.fromList(audio),
      sampleRate: json['sample_rate'] as int,
      channels: json['channels'] as int,
      format: json['format'] as String,
      boundaries: boundaries,
    );
  }

  Future<void> _generateAndPlay() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _sentences = [];
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
      final audioChunks = <Uint8List>[];
      final allBoundaries = <List<WordBoundary>>[];

      for (int i = 0; i < _sentences.length; i++) {
        if (!mounted) return;
        setState(() {
          _statusMessage = '正在合成第 ${i + 1}/${_sentences.length} 句';
        });

        final sentence = _sentences[i];
        final result = await _synthesizeText(sentence.text, _selectedVoice, _speed, _pitch, _volume);
        audioChunks.add(result.audio);
        allBoundaries.add(result.boundaries);
      }

      if (!mounted) return;

      _sentenceAudioOffsetsMs = [];
      int offsetMs = 0;
      for (int i = 0; i < allBoundaries.length; i++) {
        _sentenceAudioOffsetsMs.add(offsetMs);
        final boundaries = allBoundaries[i];
        if (boundaries.isNotEmpty) {
          final last = boundaries.last;
          offsetMs += (last.audioOffsetMs + last.durationMs).round();
        }
      }

      final combined = <int>[];
      for (final chunk in audioChunks) {
        combined.addAll(chunk);
      }

      if (!mounted) return;

      await _audioPlayer.setAudioSource(
        _AudioSourceFromBytes(Uint8List.fromList(combined)),
      );

      if (!mounted) return;
      setState(() {
        _currentSentenceIndex = 0;
        _statusMessage = '播放中';
      });

      await _audioPlayer.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = '错误：$e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isGenerating = false;
      });
    }
  }

  Future<void> _togglePause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> _exportWav() async {
    if (_sentences.isEmpty) {
      _segmentText();
      if (_sentences.isEmpty) return;
    }

    if (!mounted) return;
    setState(() {
      _statusMessage = '正在导出...';
    });

    try {
      final audioChunks = <Uint8List>[];

      for (final sentence in _sentences) {
        if (!mounted) return;
        final result = await _synthesizeText(sentence.text, _selectedVoice, _speed, _pitch, _volume);
        audioChunks.add(result.audio);

        if (sentence.breakTimeMs > 0) {
          final silence = WavConcat.createSilence(sentence.breakTimeMs);
          audioChunks.add(silence);
        }
      }

      if (!mounted) return;

      final combined = WavConcat.concatenate(audioChunks);

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${directory.path}/sayit_export_$timestamp.wav';

      await File(filePath).writeAsBytes(combined);

      if (!mounted) return;
      setState(() {
        _statusMessage = '已导出到: $filePath';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = '导出错误：$e';
      });
    }
  }

  Future<void> _importText() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      _textController.text = content;
      _segmentText();
    }
  }

  Future<void> _importSettings() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result != null && result.files.single.path != null) {
      try {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        final settings = jsonDecode(content) as Map<String, dynamic>;

        final validLanguageCodes = languages.map((l) => l['code']!).toSet();
        final validGenders = {'female', 'male'};
        final validVoiceNames = voiceData.map((v) => v.name).toSet();

        final importedVoice = settings['voice'] as String?;
        final importedLanguage = settings['language'] as String?;
        final importedGender = settings['gender'] as String?;
        final importedSpeed = (settings['speed'] as num?)?.toDouble();
        final importedPitch = (settings['pitch'] as num?)?.toDouble();
        final importedVolume = (settings['volume'] as num?)?.toDouble();

        if (!mounted) return;
        setState(() {
          if (importedVoice != null && validVoiceNames.contains(importedVoice)) {
            _selectedVoice = importedVoice;
            _selectedLanguage = importedLanguage != null && validLanguageCodes.contains(importedLanguage)
                ? importedLanguage
                : _selectedLanguage;
            _selectedGender = importedGender != null && validGenders.contains(importedGender)
                ? importedGender
                : _selectedGender;
          }
          if (importedSpeed != null && importedSpeed >= 0.5 && importedSpeed <= 2.0) {
            _speed = importedSpeed;
          }
          if (importedPitch != null && importedPitch >= -1.0 && importedPitch <= 1.0) {
            _pitch = importedPitch;
          }
          if (importedVolume != null && importedVolume >= 0.0 && importedVolume <= 2.0) {
            _volume = importedVolume;
          }
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
  }

  Future<void> _exportSettings() async {
    final settings = {
      'voice': _selectedVoice,
      'language': _selectedLanguage,
      'gender': _selectedGender,
      'speed': _speed,
      'pitch': _pitch,
      'volume': _volume,
    };

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filePath = '${directory.path}/sayit_settings_$timestamp.json';

    final file = File(filePath);
    await file.writeAsString(jsonEncode(settings));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('设定已导出: $filePath')),
    );
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('说吧'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本: v0.1'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('说吧'),
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
            SingleChildScrollView(
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
                  Row(
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
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        tooltip: _isPlaying ? '暂停' : '继续',
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: (_isPlaying || _totalDuration.inMilliseconds > 0) ? () => _audioPlayer.stop() : null,
                        icon: const Icon(Icons.stop),
                        tooltip: '停止',
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isGenerating ? null : _exportWav,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('导出'),
                      ),
                      const Spacer(),
                      DropdownButton<String>(
                        value: _selectedLanguage,
                        items: languages.map((l) => DropdownMenuItem(
                          value: l['code'],
                          child: Text(l['name']!, style: const TextStyle(fontSize: 12)),
                        )).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedLanguage = value;
                              final filtered = _filteredVoices;
                              if (filtered.isNotEmpty) {
                                _selectedVoice = filtered.first.value;
                              }
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 4),
                      DropdownButton<String>(
                        value: _selectedGender,
                        items: genders.map((g) => DropdownMenuItem(
                          value: g['code'],
                          child: Text(g['name']!, style: const TextStyle(fontSize: 12)),
                        )).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedGender = value;
                              final filtered = _filteredVoices;
                              if (filtered.isNotEmpty) {
                                _selectedVoice = filtered.first.value;
                              }
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: DropdownButton<String>(
                          value: _selectedVoice,
                          isExpanded: true,
                          items: _filteredVoices.map((v) => DropdownMenuItem(
                            value: v.value,
                            child: Text(v.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                          )).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _selectedVoice = value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  if (_isPlaying || _totalDuration.inMilliseconds > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Text(_formatDuration(_currentPosition)),
                          Expanded(
                            child: Slider(
                              value: _totalDuration.inMilliseconds > 0
                                  ? _currentPosition.inMilliseconds.toDouble()
                                  : 0,
                              min: 0,
                              max: _totalDuration.inMilliseconds > 0
                                  ? _totalDuration.inMilliseconds.toDouble()
                                  : 1,
                              onChanged: (value) {
                                _audioPlayer.seek(Duration(milliseconds: value.round()));
                              },
                            ),
                          ),
                          Text(_formatDuration(_totalDuration)),
                        ],
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
                          label: _pitch >= 0 ? '+${(_pitch * 50).round()}Hz' : '${(_pitch * 50).round()}Hz',
                          onChanged: (value) {
                            setState(() {
                              _pitch = value;
                            });
                          },
                        ),
                      ),
                      Text(_pitch >= 0 ? '+${(_pitch * 50).round()}Hz' : '${(_pitch * 50).round()}Hz'),
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
                          final result = await _synthesizeText(
                              sentence.text, _selectedVoice, _speed, _pitch, _volume);
                          await _audioPlayer.setAudioSource(
                            _AudioSourceFromBytes(result.audio),
                          );
                          await _audioPlayer.play();
                        } catch (e) {
                          debugPrint('Play error: $e');
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.indigo[100]
                              : Colors.transparent,
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
                                  color: isActive
                                      ? Colors.indigo
                                      : Colors.grey,
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
                            Text(
                              '${sentence.breakTimeMs}ms',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
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

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _AudioSourceFromBytes extends StreamAudioSource {
  final Uint8List _bytes;

  _AudioSourceFromBytes(this._bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;

    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: 'audio/mpeg',
    );
  }
}
