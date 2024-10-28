library blaze_engine;

import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class BlazeDownloader {
  final String url;
  final int maxRetries;
  final bool forceDownload;
  final Duration retryDuration;
  final bool retryAllowed;
  final void Function(int downloadedBytes, int totalBytes)?
      onProgress; // Progress callback
  final void Function(String status)? onStatusChange; // Status change callback
  final void Function()? onDownloadComplete; // Download complete callback

  BlazeDownloader(
    this.url, {
    this.maxRetries = 3,
    this.forceDownload = false,
    this.retryDuration = const Duration(milliseconds: 100),
    this.retryAllowed = true,
    this.onProgress,
    this.onStatusChange,
    this.onDownloadComplete,
  });

  Future<void> download() async {
    final Directory? downloadsDir = await getDownloadsDirectory();
    if (downloadsDir == null) {
      _notifyStatus('Could not access downloads directory.');
      return;
    }

    final String fileName = path.basename(Uri.parse(url).path);
    final File file = File('${downloadsDir.path}/$fileName');

    if (forceDownload && await file.exists()) {
      await file.delete();
      _notifyStatus('Existing file deleted, starting download from scratch.');
    }

    int startByte = await _getExistingFileSize(file);

    if (startByte > 0 && await _isFileComplete(file) && !forceDownload) {
      _notifyStatus('File already fully downloaded: ${file.path}');
      _notifyDownloadComplete();
      return;
    }

    for (int attempt = 1;
        attempt <= (retryAllowed ? maxRetries : 1);
        attempt++) {
      try {
        await _performDownload(file, startByte);
        _notifyDownloadComplete(); // Trigger complete callback on success
        return;
      } catch (e) {
        _notifyStatus('Attempt $attempt failed: $e');
        if (attempt == maxRetries || !retryAllowed) {
          _notifyStatus('Download failed.');
          return;
        }
        await Future.delayed(retryDuration);
      }
    }
  }

  Future<int> _getExistingFileSize(File file) async {
    try {
      if (await file.exists()) {
        int size = await file.length();
        _notifyStatus('Resuming download from byte: $size');
        return size;
      } else {
        _notifyStatus('Starting download from scratch.');
        return 0;
      }
    } catch (e) {
      _notifyStatus('Error checking existing file size: $e');
      return 0;
    }
  }

  Future<bool> _isFileComplete(File file) async {
    try {
      final HttpClientRequest request =
          await HttpClient().getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close();

      return (response.statusCode == 200 || response.statusCode == 206) &&
          (await file.length() == response.contentLength);
    } catch (e) {
      _notifyStatus('Error verifying file completeness: $e');
      return false;
    }
  }

  Future<void> _performDownload(File file, int startByte) async {
    final HttpClient client = HttpClient();
    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$startByte-');

    try {
      final HttpClientResponse response = await request.close();

      if (response.statusCode == 200 || response.statusCode == 206) {
        final expectedSize = response.contentLength; // Handle null case
        await _writeToFile(file, response, startByte, expectedSize);
      } else if (response.statusCode == 416) {
        _notifyStatus('Error 416: Requested Range Not Satisfiable.');
        await _handleRangeError(file, response);
      } else {
        throw Exception('Failed to download file: ${response.statusCode}');
      }
    } catch (e) {
      _notifyStatus('Error during download: $e');
      rethrow;
    }
  }

  Future<void> _handleRangeError(File file, HttpClientResponse response) async {
    _notifyStatus(
        'The file on the server may have changed. Starting download from scratch.');
    try {
      await file.delete();
    } catch (e) {
      _notifyStatus('Error deleting corrupted file: $e');
    }
    await download();
  }

  Future<void> _writeToFile(File file, HttpClientResponse response,
      int startByte, int expectedSize) async {
    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    int downloadedBytes = startByte;

    try {
      await for (var data in response) {
        sink.add(data);
        downloadedBytes += data.length;
        _notifyProgress(downloadedBytes, expectedSize);
      }

      await sink.flush();
    } catch (e) {
      _notifyStatus('Error writing to file: $e');
    } finally {
      await sink.close();
    }

    try {
      int actualSize = await file.length();
      if (actualSize != expectedSize) {
        _notifyStatus(
            'File size mismatch! Expected: $expectedSize, Downloaded: $actualSize');
        await file.delete();
        _notifyStatus('Corrupted file deleted.');
      } else {
        _notifyStatus(
            'File integrity check passed. Download completed: ${file.path}');
      }
    } catch (e) {
      _notifyStatus('Error verifying file size: $e');
    }
  }

  void _notifyProgress(int downloadedBytes, int totalBytes) {
    onProgress?.call(downloadedBytes, totalBytes);
  }

  void _notifyStatus(String status) {
    if (onStatusChange != null) {
      onStatusChange!(status); // Call the callback
    } else {
      print(status); // Print the status if the callback is null
    }
  }

  void _notifyDownloadComplete() {
    onDownloadComplete?.call();
  }
}
