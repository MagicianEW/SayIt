import 'dart:typed_data';

class WavConcat {
  static const int _riffHeaderSize = 44;
  static const int _bitsPerSample = 16;
  static const int _numChannels = 1;
  static const int _sampleRate = 16000;

  static Uint8List concatenate(List<Uint8List> audioChunks) {
    if (audioChunks.isEmpty) {
      return Uint8List(0);
    }

    if (audioChunks.length == 1) {
      return audioChunks.first;
    }

    int totalDataSize = 0;
    for (final chunk in audioChunks) {
      totalDataSize += chunk.length;
    }

    final riff = _buildRiffHeader(totalDataSize);
    final result = Uint8List(_riffHeaderSize + totalDataSize);

    result.setRange(0, _riffHeaderSize, riff);

    int offset = _riffHeaderSize;
    for (final chunk in audioChunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    return result;
  }

  static Uint8List createSilence(int durationMs) {
    final numSamples = (_sampleRate * durationMs / 1000).round();
    final numBytes = numSamples * _numChannels * (_bitsPerSample ~/ 8);

    final data = Uint8List(numBytes);
    if (_bitsPerSample == 16) {
      for (int i = 0; i < numBytes; i += 2) {
        data[i] = 0x00;
        data[i + 1] = 0x00;
      }
    }

    return concatenate([data]);
  }

  static Uint8List _buildRiffHeader(int dataSize) {
    final buffer = ByteData(_riffHeaderSize);

    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x49);
    buffer.setUint8(2, 0x46);
    buffer.setUint8(3, 0x46);

    buffer.setUint32(4, 36 + dataSize, Endian.little);

    buffer.setUint8(8, 0x57);
    buffer.setUint8(9, 0x41);
    buffer.setUint8(10, 0x56);
    buffer.setUint8(11, 0x45);

    buffer.setUint8(12, 0x66);
    buffer.setUint8(13, 0x6D);
    buffer.setUint8(14, 0x74);
    buffer.setUint8(15, 0x20);

    buffer.setUint8(16, 0x10);
    buffer.setUint8(17, 0x00);
    buffer.setUint8(18, 0x00);
    buffer.setUint8(19, 0x00);

    buffer.setUint16(20, 1, Endian.little);

    buffer.setUint16(22, _numChannels, Endian.little);
    buffer.setUint32(24, _sampleRate, Endian.little);
    buffer.setUint32(28, _sampleRate * _numChannels * (_bitsPerSample ~/ 8), Endian.little);
    buffer.setUint16(32, _numChannels * (_bitsPerSample ~/ 8), Endian.little);
    buffer.setUint16(34, _bitsPerSample, Endian.little);

    buffer.setUint8(36, 0x64);
    buffer.setUint8(37, 0x61);
    buffer.setUint8(38, 0x74);
    buffer.setUint8(39, 0x61);

    buffer.setUint32(40, dataSize, Endian.little);

    return buffer.buffer.asUint8List();
  }

  static bool isValidWav(Uint8List data) {
    if (data.length < _riffHeaderSize) return false;

    return data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x41 &&
        data[10] == 0x56 &&
        data[11] == 0x45;
  }

  static ({int sampleRate, int channels, int bitsPerSample, int dataSize}) parseHeader(
      Uint8List data) {
    if (!isValidWav(data)) {
      throw FormatException('Invalid WAV file: missing RIFF header');
    }

    final buffer = ByteData.sublistView(data);

    return (
      sampleRate: buffer.getUint32(24, Endian.little),
      channels: buffer.getUint16(22, Endian.little),
      bitsPerSample: buffer.getUint16(34, Endian.little),
      dataSize: buffer.getUint32(40, Endian.little),
    );
  }
}
