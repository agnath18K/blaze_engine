import 'dart:io';
import 'package:blaze_engine/src/logger.dart';
import 'package:path/path.dart' as path;

class SequentialDownload {
  final String downloadUrl;
  String destinationPath;
  final bool allowResume;
  final Function(double progress)? onProgress;
  final Function(String filePath)? onComplete;
  final Function(String error)? onError;
  final Logger logger;

  SequentialDownload({
    required this.downloadUrl,
    required this.destinationPath,
    this.allowResume = false,
    this.onProgress,
    this.onComplete,
    this.onError,
    LogLevel logLevel = LogLevel.info,
  }) : logger = Logger(logLevel: logLevel);

  Future<int> _getFileSizeFromUrl(String url) async {
    final client = HttpClient();
    try {
      final request = await client.headUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final contentLength = response.headers.value('content-length');
        if (contentLength != null) {
          return int.parse(contentLength);
        }
      } else {
        logger.debug(
            'Failed to get file size with status code: ${response.statusCode}');
      }
    } catch (e) {
      _logError('Error while getting file size', e);
    } finally {
      client.close();
    }
    return 0;
  }

  Future<bool> _isResumable(String url) async {
    final client = HttpClient();
    try {
      final request = await client.headUrl(Uri.parse(url));
      final response = await request.close();
      return response.headers.value('accept-ranges') == 'bytes';
    } catch (e) {
      _logError('Error while checking if server supports resuming', e);
    } finally {
      client.close();
    }
    return false;
  }

  Future<void> startDownload() async {
    final dir = Directory(destinationPath);
    if (await dir.exists()) {
      final fileName = _getFileNameFromUrl(downloadUrl);
      destinationPath = path.join(destinationPath, fileName);
    }

    final file = File(destinationPath);
    int startByte = 0;
    int totalSize = await _getFileSizeFromUrl(downloadUrl);

    if (totalSize == 0) {
      _logError('Could not retrieve file size. Aborting download.');
      return;
    }

    if (await file.exists()) {
      int existingFileSize = await _getFileSizeFromPath(destinationPath);
      if (existingFileSize == totalSize) {
        logger.info('File already fully downloaded: $destinationPath');
        onComplete?.call(destinationPath);
        return;
      } else {
        if (allowResume && await _isResumable(downloadUrl)) {
          startByte = existingFileSize;
          logger.info('Resuming download from byte: $startByte');
        } else {
          logger.info('Deleting incomplete file and starting new download...');
          await file.delete();
        }
      }
    } else {
      logger.info('Starting new download...');
    }

    await _downloadFile(file, startByte, totalSize);
  }

  String _getFileNameFromUrl(String url) {
    return Uri.parse(url).pathSegments.last;
  }

  Future<void> _downloadFile(File file, int startByte, int totalSize) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse(downloadUrl))
          .timeout(Duration(seconds: 30));
      request.headers.add('Range', 'bytes=$startByte-${totalSize - 1}');
      final response = await request.close();

      if (response.statusCode == 206 || response.statusCode == 200) {
        int bytesDownloaded = startByte;
        final fileSink = file.openWrite(mode: FileMode.append);

        await for (var data in response) {
          fileSink.add(data);
          bytesDownloaded += data.length;

          if (bytesDownloaded - startByte >= (totalSize ~/ 100) ||
              bytesDownloaded == totalSize) {
            final progress = (bytesDownloaded / totalSize) * 100;
            onProgress?.call(progress);
            logger.debug('Progress: ${progress.toStringAsFixed(2)}%');
          }
        }

        await fileSink.close();
        await _checkFileIntegrity(destinationPath, totalSize);
        onComplete?.call(destinationPath);
      } else {
        _logError('Download failed with status code: ${response.statusCode}');
      }
    } catch (e) {
      _logError('Error during download', e);
    } finally {
      client.close();
    }
  }

  Future<int> _getFileSizeFromPath(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final fileStat = await file.stat();
        return fileStat.size;
      } else {
        logger.warning('File does not exist: $path');
      }
    } catch (e) {
      _logError('Error while getting file size from path', e);
    }
    return 0;
  }

  Future<void> _checkFileIntegrity(String path, int expectedSize) async {
    final file = File(path);
    if (!await file.exists()) {
      _logError('File does not exist: $path');
      return;
    }

    final downloadedSize = await _getFileSizeFromPath(path);
    if (expectedSize == downloadedSize) {
      logger.info(
          'Download completed successfully: $path, Size: $downloadedSize bytes');
    } else {
      _logError(
          'File corrupted: Expected size $expectedSize bytes, but got $downloadedSize bytes');
    }
  }

  void _logError(String message, [Object? e]) {
    final errorMessage = e != null ? '$message: ${e.toString()}' : message;
    logger.error(errorMessage);
    onError?.call(errorMessage);
  }
}
