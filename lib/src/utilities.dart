import 'dart:io';

bool isDebugModeEnabled = false;

class Utilities {
  static void debugPrint(String message) {
    if (isDebugModeEnabled) {
      print(message);
    }
  }

  static String getFileNameFromUrl(String url) {
    return url.split('/').last;
  }

  static Future<String> createFile(
      String directoryPath, String fileName) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return '${directory.path}/$fileName';
  }
}
