import 'dart:io';
import 'dart:isolate';

import 'package:blaze_engine/src/logger.dart';
import 'package:blaze_engine/src/utilities.dart';

class SegmentControlled {
  final String downloadUrl;
  final String destinationPath;
  final int segmentCount;
  final int workerCount;
  final int maxRetries;
  final void Function(double progress)? onProgress;
  final void Function(String filePath)? onComplete;
  final void Function(String error)? onError;
  final Logger logger;

  SegmentControlled({
    required this.downloadUrl,
    required this.destinationPath,
    this.segmentCount = 8,
    this.workerCount = 4,
    this.maxRetries = 3,
    this.onProgress,
    this.onComplete,
    this.onError,
    LogLevel logLevel = LogLevel.info,
  }) : logger = Logger(logLevel: logLevel);

  static String getFileNameFromUrl(String url) {
    return url.split('/').last;
  }

  String _validateDestinationPath(String destinationPath, String downloadUrl) {
    final path = Directory(destinationPath);
    if (path.existsSync()) {
      return '$destinationPath/${getFileNameFromUrl(downloadUrl)}';
    } else if (destinationPath.endsWith('/')) {
      return '$destinationPath${getFileNameFromUrl(downloadUrl)}';
    }
    return destinationPath;
  }

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
        final errorMsg =
            'Failed to get file size with status code: ${response.statusCode}';
        logger.debug(errorMsg);
        onError?.call(errorMsg);
      }
    } catch (e) {
      final errorMsg = 'Error while getting file size: $e';
      logger.error(errorMsg);
      onError?.call(errorMsg);
    } finally {
      client.close();
    }
    return 0;
  }

  Future<void> startDownload() async {
    final validDestinationPath =
        _validateDestinationPath(destinationPath, downloadUrl);
    int totalSize = await _getFileSizeFromUrl(downloadUrl);
    if (totalSize == 0) {
      onError?.call("Unable to fetch file size.");
      return;
    }

    final segmentSize = (totalSize / segmentCount).ceil();
    int bytesDownloaded = 0;

    List<String> segmentFiles = [];
    List<Map<String, int>> segmentRanges = [];

    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;
      segmentRanges.add({'startByte': startByte, 'endByte': endByte});

      final segmentFile = await Utilities.createFile(
          destinationPath, '${getFileNameFromUrl(downloadUrl)}_part$i');
      segmentFiles.add(segmentFile);
    }

    List<ReceivePort> isolateReceivePorts = [];
    bool downloadFailed = false;
    List<Isolate> isolates = [];

    for (int i = 0; i < segmentCount; i++) {
      final port = ReceivePort();
      isolateReceivePorts.add(port);

      final isolate = await Isolate.spawn(_workerMainForFixedSegment, [
        port.sendPort,
        downloadUrl,
        segmentRanges[i],
        segmentFiles[i],
        maxRetries,
      ]);
      isolates.add(isolate);

      port.listen((message) async {
        if (message is String && message.startsWith('Error')) {
          onError?.call("Segment Error");
          downloadFailed = true;
          logger.error(message);
        } else if (message is Map<String, dynamic>) {
          bytesDownloaded += message['bytesDownloaded'] as int;
          final progress = (bytesDownloaded / totalSize) * 100;
          onProgress?.call(progress);
          logger.info('Progress: ${progress.toStringAsFixed(2)}%');

          if (bytesDownloaded >= totalSize) {
            logger.info('Download Complete!');
          }
        }
      });
    }

    while (bytesDownloaded < totalSize && !downloadFailed) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    if (downloadFailed) {
      logger.error('Download failed, cleaning up segment files.');
      await _cleanupSegmentFiles(segmentFiles);
      onError?.call("Download failed.");
      return;
    }

    await _mergeFileSegments(segmentFiles, validDestinationPath);
    await _checkFileIntegrity(validDestinationPath, totalSize);
    await _cleanupSegmentFiles(segmentFiles);
  }

  static void _workerMainForFixedSegment(List<dynamic> args) async {
    SendPort mainSendPort = args[0];
    final downloadUrl = args[1];
    final range = args[2] as Map<String, int>;
    final segmentFilePath = args[3];

    try {
      final request = await HttpClient().getUrl(Uri.parse(downloadUrl));

      request.headers
          .add('Range', 'bytes=${range['startByte']}-${range['endByte']}');
      final response = await request.close();

      if (response.statusCode == 206) {
        final file = File(segmentFilePath);
        final fileSink = file.openWrite();

        await for (var data in response) {
          fileSink.add(data);
          mainSendPort.send({'bytesDownloaded': data.length});
        }
        await fileSink.close();
        mainSendPort.send(
            'Segment ${range['startByte']}-${range['endByte']} downloaded successfully.');
      } else {
        mainSendPort.send('Error: Server response was ${response.statusCode}');
      }
    } catch (e) {
      mainSendPort.send(
          'Error downloading segment ${range['startByte']}-${range['endByte']}: $e');
    } finally {
      HttpClient().close();
    }
  }

  Future<void> _mergeFileSegments(
      List<String> segmentFiles, String outputFilePath) async {
    final outputFile = File(outputFilePath);
    final sink = outputFile.openWrite();

    try {
      for (String segmentFile in segmentFiles) {
        final segment = File(segmentFile);
        if (!await segment.exists()) {
          final errorMsg = 'Segment file missing: $segmentFile';
          logger.error(errorMsg);
          onError?.call(errorMsg);
          return;
        }

        await for (var data in segment.openRead()) {
          sink.add(data);
        }
        logger.info('Merged segment file: $segmentFile into $outputFilePath');
      }
      logger.info('All segments merged into: ${outputFile.path}');
    } catch (e) {
      final errorMsg = 'Error merging file segments: $e';
      logger.error(errorMsg);
      onError?.call(errorMsg);
    } finally {
      await sink.close();
    }
  }

  Future<void> _cleanupSegmentFiles(List<String> segmentFiles) async {
    for (var segmentFile in segmentFiles) {
      try {
        final file = File(segmentFile);
        if (await file.exists()) {
          await file.delete();
          logger.info('Deleted segment file: $segmentFile');
        }
      } catch (e) {
        final errorMsg = 'Error deleting segment file: $segmentFile, Error: $e';
        logger.error(errorMsg);
        onError?.call(errorMsg);
      }
    }
  }

  Future<void> _checkFileIntegrity(String filePath, int expectedSize) async {
    final downloadedSize = await _getFileSizeFromPath(filePath);
    if (expectedSize == downloadedSize) {
      logger.info(
          'Download completed successfully: $filePath, Size: $downloadedSize bytes');
      onComplete?.call(filePath);
    } else {
      final errorMsg =
          'File size mismatch. Expected $expectedSize, got $downloadedSize';
      logger.error(errorMsg);
      onError?.call(errorMsg);
    }
  }

  Future<int> _getFileSizeFromPath(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final fileStat = await file.stat();
        return fileStat.size;
      } else {
        final errorMsg = 'File does not exist: $filePath';
        logger.error(errorMsg);
        onError?.call(errorMsg);
      }
    } catch (e) {
      final errorMsg = 'Error while getting file size: $e';
      logger.error(errorMsg);
      onError?.call(errorMsg);
    }
    return 0;
  }
}
