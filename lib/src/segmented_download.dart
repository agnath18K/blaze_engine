import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'package:blaze_engine/src/utilities.dart';
import 'package:hive/hive.dart';
import 'segment_model.dart';
import 'logger.dart';

class SegmentedDownload {
  final String downloadUrl;
  final String destinationPath;
  final int segmentCount;
  final int workerCount;
  final int maxRetries;
  final void Function(double progress)? onProgress;
  final void Function(String filePath)? onComplete;
  final void Function(String error)? onError;
  final Logger logger;

  SegmentedDownload({
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

  Future<void> startDownload() async {
    Hive.init(destinationPath);
    logger.info('Initializing download from $downloadUrl to $destinationPath');

    if (segmentCount <= 0 || workerCount <= 0) {
      logger.error('Segment count and worker count must be greater than zero.');
      throw Exception('Invalid segment or worker count.');
    }

    final fileName = Utilities.getFileNameFromUrl(downloadUrl);
    final filePath = await Utilities.createFile(destinationPath, fileName);
    logger.info('File will be saved as: $filePath');

    try {
      final totalSize = await _getFileSizeFromUrl(downloadUrl);
      if (totalSize == 0) {
        onError?.call('Could not retrieve file size. Aborting download.');
        return;
      }

      logger.info("Total file size: $totalSize bytes");
      await _downloadWithWorkerPool(fileName, filePath, totalSize);
      logger.info(
          'Download completed successfully. Merged file created at: $filePath');
      onComplete?.call(filePath);
    } catch (e) {
      logger.error('Error during download: $e');
      onError?.call(e.toString());
    }
  }

  Future<void> _downloadWithWorkerPool(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();
    final workerReceivePorts = <ReceivePort>[];
    final segmentFiles = <String>[];
    final downloadSegmentQueue = <Map<String, int>>[];
    int bytesDownloaded = 0;

    logger.info('Preparing download segments...');

    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;

      downloadSegmentQueue.add({'startByte': startByte, 'endByte': endByte});
      final segmentFile =
          await Utilities.createFile(destinationPath, '$fileName.part$i');
      segmentFiles.add(segmentFile);

      await _storeSegment(
          fileName,
          DownloadSegment(
            segmentFilePath: segmentFile,
            segmentIndex: i,
            startByte: startByte,
            endByte: endByte,
            status: "pending",
          ));
      logger.info(
          'Segment $i prepared: $segmentFile from $startByte to $endByte');
    }

    logger.info('Starting worker creation with $workerCount workers.');
    bool downloadFailed = false;
    final workers = <Isolate>[];

    for (int i = 0; i < workerCount; i++) {
      final port = ReceivePort();
      workerReceivePorts.add(port);

      final worker =
          await Isolate.spawn(_workerMainForPoolQueue, [port.sendPort, this]);
      workers.add(worker);

      port.listen((message) async {
        if (message is SendPort) {
          while (downloadSegmentQueue.isNotEmpty) {
            final task = downloadSegmentQueue.removeAt(0);
            message.send([
              task['startByte'],
              task['endByte'],
              downloadUrl,
              segmentFiles[
                  segmentFiles.length - downloadSegmentQueue.length - 1],
              maxRetries
            ]);
            logger.info(
                'Task sent to worker: ${task['startByte']}-${task['endByte']}');
          }
        } else if (message is String && message.startsWith('Error')) {
          logger.error("Segment download failed: $message");
          onError?.call("Segment Error");
          downloadFailed = true;
        } else if (message is Map<String, dynamic>) {
          bytesDownloaded += message['bytesDownloaded'] as int;
          final progress = (bytesDownloaded / totalSize) * 100;
          onProgress?.call(progress);
          logger.info('Progress: ${progress.toStringAsFixed(2)}%');
        }
      });
    }

    while (bytesDownloaded < totalSize && !downloadFailed) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    if (downloadFailed) {
      logger.error('Download failed, cleaning up segment files.');
      await _cleanupSegmentFiles(segmentFiles);
      return;
    }

    await _mergeFileSegments(segmentFiles, filePath);
    await _checkFileIntegrity(filePath, totalSize);
    await _cleanupSegmentFiles(segmentFiles);
  }

  void _workerMainForPoolQueue(List<dynamic> args) async {
    final SendPort mainSendPort = args[0];
    final SegmentedDownload instance = args[1];

    final ReceivePort workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);

    workerReceivePort.listen((message) async {
      if (message is List<dynamic>) {
        final startByte = message[0];
        final endByte = message[1];
        final downloadUrl = message[2];
        final segmentFilePath = message[3];

        try {
          instance.logger
              .info('Worker downloading segment: $startByte-$endByte');
          final request = await HttpClient().getUrl(Uri.parse(downloadUrl));
          request.headers.add('Range', 'bytes=$startByte-$endByte');
          final response = await request.close();

          if (response.statusCode == 206) {
            final file = File(segmentFilePath);
            final fileSink = file.openWrite();

            await for (var data in response) {
              fileSink.add(data);
              mainSendPort.send({'bytesDownloaded': data.length});
            }
            await fileSink.close();
            mainSendPort
                .send('Segment $startByte-$endByte downloaded successfully.');
            instance.logger
                .info('Segment $startByte-$endByte downloaded successfully.');
          } else {
            mainSendPort
                .send('Error: Server response was ${response.statusCode}');
          }
        } catch (e) {
          mainSendPort
              .send('Error downloading segment $startByte-$endByte: $e');
          instance.logger
              .error('Error downloading segment $startByte-$endByte: $e');
        }
      }
    });
  }

  Future<void> _storeSegment(String filename, DownloadSegment segment) async {
    try {
      var box = await Hive.openBox(filename);
      await box.put(segment.segmentFilePath, {
        'segmentFilePath': segment.segmentFilePath,
        'segmentIndex': segment.segmentIndex,
        'startByte': segment.startByte,
        'endByte': segment.endByte,
        'status': segment.status,
      });
      logger.info('Segment stored in Hive: ${segment.segmentFilePath}');
    } catch (e) {
      logger.error('Error storing segment: $e');
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
          logger.warning('Segment file does not exist: $segmentFile');
          return;
        }

        await for (var data in segment.openRead()) {
          sink.add(data);
        }
        logger.info('Merged segment file: $segmentFile into $outputFilePath');
      }
      logger.info('Merged file created at: ${outputFile.path}');
    } catch (e) {
      logger.error('Error merging file segments: $e');
      onError?.call(e.toString());
    } finally {
      await sink.close();
    }
  }

  Future<void> _checkFileIntegrity(String filePath, int expectedSize) async {
    final downloadedSize = await _getFileSizeFromPath(filePath);
    if (expectedSize == downloadedSize) {
      logger.info(
          'Download completed successfully: $filePath, Size: $downloadedSize bytes');
    } else {
      logger.warning(
          'File corrupted: Expected size $expectedSize bytes, but got $downloadedSize bytes');
    }
  }

  Future<int> _getFileSizeFromUrl(String url) async {
    try {
      final request = await HttpClient().headUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final contentLength = response.headers.value('content-length');
        if (contentLength != null) {
          return int.parse(contentLength);
        }
      }
      return 0;
    } catch (e) {
      logger.error('Error while getting file size: $e');
      onError?.call(e.toString());
    }
    return 0;
  }

  Future<int> _getFileSizeFromPath(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      final fileStat = await file.stat();
      return fileStat.size;
    }
    return 0;
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
        logger.error('Error deleting segment file $segmentFile: $e');
      }
    }
  }
}
