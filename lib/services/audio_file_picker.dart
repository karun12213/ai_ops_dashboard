import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

const supportedAudioExtensions = {
  'mp3',
  'wav',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'mp4',
};
const maxAudioUploadBytes = 100 * 1024 * 1024;

class PickedAudioFile {
  const PickedAudioFile({
    required this.name,
    required this.sizeBytes,
    required this.openRead,
    this.mediaType,
  });

  final String name;
  final int sizeBytes;
  final Stream<List<int>> Function() openRead;
  final String? mediaType;

  String get extension {
    final separator = name.lastIndexOf('.');
    return separator < 0 ? '' : name.substring(separator + 1).toLowerCase();
  }

  String get effectiveMediaType =>
      mediaType ?? audioMediaTypeForExtension(extension);

  Future<Uint8List> readBytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in openRead()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

String audioMediaTypeForExtension(String extension) => switch (extension) {
  'mp3' => 'audio/mpeg',
  'wav' => 'audio/wav',
  'm4a' => 'audio/mp4',
  'aac' => 'audio/aac',
  'ogg' => 'audio/ogg',
  'opus' => 'audio/ogg',
  'mp4' => 'audio/mp4',
  _ => 'application/octet-stream',
};

abstract interface class AudioFilePicker {
  Future<PickedAudioFile?> pickAudio();
}

class PlatformAudioFilePicker implements AudioFilePicker {
  const PlatformAudioFilePicker();

  @override
  Future<PickedAudioFile?> pickAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedAudioExtensions.toList(growable: false),
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (result == null) return null;
    final platformFile = result.files.single;
    if (kIsWeb) {
      final bytes = platformFile.bytes;
      if (bytes == null) {
        throw StateError(
          'The browser did not provide the selected file bytes.',
        );
      }
      return PickedAudioFile(
        name: platformFile.name,
        sizeBytes: bytes.length,
        mediaType: audioMediaTypeForExtension(platformFile.extension ?? ''),
        // A new single-subscription stream is created for every attempt. This
        // is essential when ApiClient retries multipart after token refresh.
        openRead: () => Stream<List<int>>.value(bytes),
      );
    }
    final XFile source = result.xFiles.single;
    final sizeBytes = await source.length();
    return PickedAudioFile(
      name: source.name,
      sizeBytes: sizeBytes,
      mediaType: audioMediaTypeForExtension(platformFile.extension ?? ''),
      openRead: source.openRead,
    );
  }
}
