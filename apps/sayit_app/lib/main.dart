import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'src/text_segmenter.dart';
import 'src/wav_concat.dart';

void main() {
  runApp(const SayItApp());
}

class SayItApp extends StatelessWidget {
  const SayItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SayIt',
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

  List<Sentence> _sentences = [];
  int _currentSentenceIndex = -1;
  bool _isGenerating = false;
  String? _statusMessage;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;

  static const _voices = <Map<String, String>>[
    {'name': '晓晓(女)-温柔亲切', 'value': 'zh-CN-XiaoxiaoNeural'},
    {'name': '云希(女)-活泼可爱', 'value': 'zh-CN-YunxiNeural'},
    {'name': '云扬(男)-成熟专业', 'value': 'zh-CN-YunyangNeural'},
    {'name': '云野(男)-沉稳有力', 'value': 'zh-CN-YunyeNeural'},
    {'name': '小艺(女)-青春活泼', 'value': 'zh-CN-XiaoyiNeural'},
    {'name': '云夏(女)-清新柔和', 'value': 'zh-CN-YunxiaNeural'},
    {'name': '晓涵(女)-知性冷静', 'value': 'zh-CN-XiaohanNeural'},
    {'name': '晓睿(女)-聪慧成熟', 'value': 'zh-CN-XiaoruiNeural'},
    {'name': '晓双(女)-俏皮活泼', 'value': 'zh-CN-XiaoshuangNeural'},
    {'name': '晓瑄(女)-温婉优雅', 'value': 'zh-CN-XiaoxuanNeural'},
    {'name': '晓燕(女)-亲和温暖', 'value': 'zh-CN-XiaoyanNeural'},
    {'name': '小雪(女)-轻柔甜美', 'value': 'zh-CN-XiaoxueNeural'},
    {'name': '云绯(女)-优雅知性', 'value': 'zh-CN-YunfeiNeural'},
    {'name': '云健(男)-健康活力', 'value': 'zh-CN-YunjianNeural'},
    {'name': '云霖(男)-沉稳温和', 'value': 'zh-CN-YunlinNeural'},
    {'name': '云龙(男)-浑厚有力', 'value': 'zh-CN-YunlongNeural'},
  ];
  String _selectedVoice = 'zh-CN-XiaoxiaoNeural';
  double _speed = 1.0;
  double _pitch = 0.0;
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    _audioPlayer.playerStateStream.listen((state) {
      setState(() {
        _isPlaying = state.playing;
      });
      if (state.processingState == ProcessingState.completed) {
        // 播放完成
      }
    });
    _audioPlayer.positionStream.listen((position) {
      setState(() {
        _currentPosition = position;
      });
    });
    _audioPlayer.durationStream.listen((duration) {
      if (duration != null) {
        setState(() {
          _totalDuration = duration;
        });
      }
    });
  }

  @override
  void dispose() {
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
    final pocBinary = '/Users/xingxiaoshu/开发/SayIt/sayit-poc/target/debug/sayit-poc';
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
    if (_isPlaying) {
      await _audioPlayer.pause();
      return;
    }

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

      for (int i = 0; i < _sentences.length; i++) {
        setState(() {
          _statusMessage = '正在合成第 ${i + 1}/${_sentences.length} 句';
        });

        final sentence = _sentences[i];
        final result = await _synthesizeText(sentence.text, _selectedVoice, _speed, _pitch, _volume);
        audioChunks.add(result.audio);

        if (sentence.breakTimeMs > 0 && i < _sentences.length - 1) {
          final silence = WavConcat.createSilence(sentence.breakTimeMs);
          audioChunks.add(silence);
        }
      }

      final combined = WavConcat.concatenate(audioChunks);

      await _audioPlayer.setAudioSource(
        _AudioSourceFromBytes(combined),
      );

      setState(() {
        _currentSentenceIndex = 0;
        _statusMessage = '播放中';
      });

      await _audioPlayer.play();
    } catch (e) {
      setState(() {
        _statusMessage = '错误：$e';
      });
    } finally {
      setState(() {
        _isGenerating = false;
      });
    }
  }

  Future<void> _exportWav() async {
    if (_sentences.isEmpty) {
      _segmentText();
      if (_sentences.isEmpty) return;
    }

    setState(() {
      _statusMessage = '正在导出...';
    });

    try {
      final audioChunks = <Uint8List>[];

      for (final sentence in _sentences) {
        final result = await _synthesizeText(sentence.text, _selectedVoice, _speed, _pitch, _volume);
        audioChunks.add(result.audio);

        if (sentence.breakTimeMs > 0) {
          final silence = WavConcat.createSilence(sentence.breakTimeMs);
          audioChunks.add(silence);
        }
      }

      final combined = WavConcat.concatenate(audioChunks);

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${directory.path}/sayit_export_$timestamp.wav';

      await File(filePath).writeAsBytes(combined);

      setState(() {
        _statusMessage = '已导出到: $filePath';
      });
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SayIt'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            onPressed: _importText,
            tooltip: '导入文本文件',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
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
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  label: Text(_isPlaying ? '暂停' : '生成并播放'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isPlaying ? () => _audioPlayer.stop() : null,
                  icon: const Icon(Icons.stop),
                  tooltip: '停止',
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isGenerating ? null : _exportWav,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('导出WAV'),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: _selectedVoice,
                  items: _voices.map((v) => DropdownMenuItem(
                    value: v['value'],
                    child: Text(v['name']!),
                  )).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedVoice = value);
                    }
                  },
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
                        if (_sentences.isNotEmpty) {
                          _statusMessage = '参数已调整，点击"重新生成"试听效果';
                        }
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
                        if (_sentences.isNotEmpty) {
                          _statusMessage = '参数已调整，点击"重新生成"试听效果';
                        }
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
                        if (_sentences.isNotEmpty) {
                          _statusMessage = '参数已调整，点击"重新生成"试听效果';
                        }
                      });
                    },
                  ),
                ),
                Text('${(_volume * 100).round()}%'),
                const SizedBox(width: 8),
                if (_sentences.isNotEmpty)
                  TextButton(
                    onPressed: _isGenerating ? null : _generateAndPlay,
                    child: const Text('重新生成'),
                  ),
              ],
            ),
            if (_statusMessage != null)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_statusMessage!),
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
      contentType: 'audio/wav',
    );
  }
}
