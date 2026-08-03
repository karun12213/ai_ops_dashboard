import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

const supportedAudioExtensions = {'mp3', 'wav', 'm4a', 'aac', 'ogg'};
const maxAudioUploadBytes = 100 * 1024 * 1024;

class PickedAudioFile {
  const PickedAudioFile({
    required this.name,
    required this.sizeBytes,
    required this.openRead,
  });

  final String name;
  final int sizeBytes;
  final Stream<List<int>> Function() openRead;

  String get extension {
    final separator = name.lastIndexOf('.');
    return separator < 0 ? '' : name.substring(separator + 1).toLowerCase();
  }
}

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
    final XFile source = result.xFiles.single;
    final sizeBytes = await source.length();
    return PickedAudioFile(
      name: source.name,
      sizeBytes: sizeBytes,
      openRead: source.openRead,
    );
  }
}
