import 'package:file_picker/file_picker.dart';

import 'report_service.dart';

abstract interface class PdfExportSaver {
  Future<void> save(ReportExport export);
}

class FilePickerPdfExportSaver implements PdfExportSaver {
  const FilePickerPdfExportSaver();

  @override
  Future<void> save(ReportExport export) async {
    await FilePicker.platform.saveFile(
      dialogTitle: 'Save AI audio report PDF',
      fileName: export.filename,
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      bytes: export.bytes,
      lockParentWindow: true,
    );
  }
}
