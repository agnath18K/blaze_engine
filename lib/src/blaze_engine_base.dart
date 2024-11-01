import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'package:blaze_engine/src/download_segment.dart';
import 'package:blaze_engine/src/utilities.dart';
import 'package:hive/hive.dart';

class BlazeDownloader {
  final String downloadUrl;
  final String customDirectory;
  final bool sequentialDownload;
  final bool enableWorkerPooling;
  final bool allowResume;
  final int segmentCount;
  final int workerCount;
  final int maxRetries;
  final void Function(double progress)? onProgress;
  final void Function(String filePath)? onComplete;
  final void Function(String error)? onError;

  BlazeDownloader({
    required this.downloadUrl,
    required this.customDirectory,
    this.allowResume = false,
    this.sequentialDownload = false,
    this.enableWorkerPooling = false,
    this.segmentCount = 20,
    this.workerCount = 4,
    this.maxRetries = 3,
    this.onProgress,
    this.onComplete,
    this.onError,
  });

  Future<void> startDownload() async {
    Hive.init(customDirectory);
    if (segmentCount <= 0 || workerCount <= 0) {
      throw Exception(
          'Segment count and worker count must be greater than zero.');
    }

    DateTime startTime = DateTime.now();
    Utilities.debugPrint(
        "Download initiated at: ${startTime.toIso8601String()}");

    final fileName = Utilities.getFileNameFromUrl(downloadUrl);

    final filePath = await Utilities.createFile(customDirectory, fileName);
    Utilities.debugPrint("File name extracted: $fileName");
    Utilities.debugPrint("File will be saved at: $filePath");

    try {
      final totalSize = await _getFileSizeFromUrl(downloadUrl);
      if (totalSize == 0) {
        Utilities.debugPrint(
            'Could not retrieve file size. Aborting download.');
        Utilities.debugPrint("Aborting download due to zero file size.");
        return;
      }
      Utilities.debugPrint("Total file size retrieved: $totalSize bytes");

      if (sequentialDownload) {
        Utilities.debugPrint("Sequential download mode enabled.");
        final canResume = await _supportsRangeRequests(downloadUrl);
        if (canResume) {
          Utilities.debugPrint(
              "Server supports range requests. Resuming download...");
          await _downloadSequential(filePath, totalSize);
        } else {
          Utilities.debugPrint(
              'Resume capability not supported, downloading the entire file...');
          await _downloadSequential(filePath, totalSize);
        }
      } else {
        if (enableWorkerPooling) {
          Utilities.debugPrint(
              "Pool queue mode enabled for segmented download.");
          await _downloadSegmentedWithWorkerPool(fileName, filePath, totalSize);
        } else {
          Utilities.debugPrint(
              "Fixed isolates mode enabled for segmented download.");
          await _downloadSegmentedFixedIsolates(fileName, filePath, totalSize);
        }
      }
      onComplete?.call(filePath);
      DateTime endTime = DateTime.now();
      Utilities.debugPrint(
          "Download completed at: ${endTime.toIso8601String()}");

      Duration difference = endTime.difference(startTime);

      Utilities.debugPrint("Download Duration:");
      Utilities.debugPrint("${difference.inDays} days");
      Utilities.debugPrint("${difference.inHours % 24} hours");
      Utilities.debugPrint("${difference.inMinutes % 60} minutes");
      Utilities.debugPrint("${difference.inSeconds % 60} seconds");
    } catch (e) {
      Utilities.debugPrint('Error during download: $e');
      onError?.call(e.toString());
      Utilities.debugPrint("An error occurred during the download process: $e");
    }
  }

  Future<void> _downloadSequential(String filePath, int totalSize) async {
    final file = File(filePath);
    int startByte = 0;

    if (allowResume && await file.exists()) {
      startByte = await _getFileSizeFromPath(filePath);
      if (startByte >= totalSize) {
        Utilities.debugPrint('File already downloaded: $filePath');
        return;
      }
      Utilities.debugPrint('Resuming download from byte: $startByte');
    } else {
      Utilities.debugPrint('Starting new download...');
    }

    final request = await HttpClient().getUrl(Uri.parse(downloadUrl));

    final endByte = totalSize - 1;
    request.headers.add('Range', 'bytes=$startByte-$endByte');

    final response = await request.close();

    if (response.statusCode == 206 || response.statusCode == 200) {
      int bytesDownloaded = startByte;

      final fileSink = file.openWrite(mode: FileMode.append);

      await for (var data in response) {
        fileSink.add(data);
        bytesDownloaded += data.length;

        final progress = (bytesDownloaded / totalSize) * 100;
        onProgress?.call(progress);
        Utilities.debugPrint('Progress: ${progress.toStringAsFixed(2)}%');
      }

      await fileSink.close();
      await _checkFileIntegrity(filePath, totalSize);
    } else {
      Utilities.debugPrint(
          'Download failed with status code: ${response.statusCode}');
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
      } else {
        Utilities.debugPrint(
            'Failed to get file size with status code: ${response.statusCode}');
      }
    } catch (e) {
      Utilities.debugPrint('Error while getting file size: $e');
      onError?.call(e.toString());
    }
    return 0;
  }

  Future<Box> openBoxByFilename(String filename) async {
    return await Hive.openBox(filename);
  }

  Future<void> storeSegment(String filename, DownloadSegment segment) async {
    try {
      var box = await openBoxByFilename(filename);
      await box.put(segment.segmentFilePath, {
        'segmentFilePath': segment.segmentFilePath,
        'segmentIndex': segment.segmentIndex,
        'startByte': segment.startByte,
        'endByte': segment.endByte,
        'status': segment.status,
      });
    } catch (e) {
      print('Error storing segment: $e');
    }

    try {
      var box = await openBoxByFilename(filename);

      var storedSegment = await box.get(segment.segmentFilePath);

      if (storedSegment != null) {
        print('Segment File Path: ${storedSegment['segmentFilePath']}');
        print('Segment Index: ${storedSegment['segmentIndex']}');
        print('Start Byte: ${storedSegment['startByte']}');
        print('End Byte: ${storedSegment['endByte']}');
        print('Status: ${storedSegment['status']}');
      } else {
        print('No segment found for key: ${segment.segmentFilePath}');
      }
    } catch (e) {
      print('Error reading segment: $e');
    }
  }

  Future<void> storeSegmentStatus(String segmentFilePath, String status) async {
    print("completed : $segmentFilePath");
    Hive.init(customDirectory);
    final fileName = Utilities.getFileNameFromUrl(downloadUrl);

    openBoxByFilename(fileName);

    try {
      var box = await openBoxByFilename(fileName);

      var existingSegment = await box.get(segmentFilePath);

      if (existingSegment != null) {
        existingSegment['status'] = "completed";

        await box.put(segmentFilePath, existingSegment);
      } else {
        print('Segment not found.');
      }
    } catch (e) {
      print('Error storing segment: $e');
    }
  }

  Future<void> _downloadSegmentedWithWorkerPool(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();

    List<ReceivePort> workerReceivePorts = [];
    List<String> segmentFiles = [];
    List<Map<String, int>> downloadSegmentQueue = [];

    int bytesDownloaded = 0;

    openBoxByFilename(fileName);

    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;

      downloadSegmentQueue.add({'startByte': startByte, 'endByte': endByte});

      final segmentFile =
          await Utilities.createFile(customDirectory, '${fileName}_part$i');
      segmentFiles.add(segmentFile);

      storeSegment(
          fileName,
          DownloadSegment(
              segmentFilePath: segmentFile,
              segmentIndex: i,
              startByte: startByte,
              endByte: endByte,
              status: "pending"));
    }

    Utilities.debugPrint('Starting worker creation with $workerCount workers.');

    bool downloadFailed = false;

    List<Isolate> workers = [];

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
          }
        } else if (message is String && message.startsWith('Error')) {
          onError?.call("Segment Error");
          downloadFailed = true;
        } else if (message is Map<String, dynamic>) {
          bytesDownloaded += message['bytesDownloaded'] as int;
          final progress = (bytesDownloaded / totalSize) * 100;
          onProgress?.call(progress);
          Utilities.debugPrint('Progress: ${progress.toStringAsFixed(2)}%');

          if (bytesDownloaded >= totalSize) {
            Utilities.debugPrint('Download Complete!');
          }
        }
      });
    }

    while (bytesDownloaded < totalSize && !downloadFailed) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    if (downloadFailed) {
      Utilities.debugPrint('Download failed, cleaning up segment files.');
      await _cleanupSegmentFiles(segmentFiles);
      return;
    }

    await _mergeFileSegments(segmentFiles, filePath);

    await _checkFileIntegrity(filePath, totalSize);

    await _cleanupSegmentFiles(segmentFiles);
  }

  Future<int> _getFileSizeFromPath(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final fileStat = await file.stat();
        return fileStat.size;
      } else {
        Utilities.debugPrint('File does not exist: $filePath');
      }
    } catch (e) {
      Utilities.debugPrint('Error while getting file size: $e');
      onError?.call(e.toString());
    }
    return 0;
  }

  static void _workerMainForPoolQueue(List<dynamic> args) async {
    SendPort mainSendPort = args[0];
    BlazeDownloader downloader = args[1];

    ReceivePort workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);

    workerReceivePort.listen((message) async {
      if (message is List<dynamic>) {
        final startByte = message[0];
        final endByte = message[1];
        final downloadUrl = message[2];
        final segmentFilePath = message[3];

        try {
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

            await downloader.storeSegmentStatus(segmentFilePath, "completed");
            mainSendPort
                .send('Segment $startByte-$endByte downloaded successfully.');
          } else {
            mainSendPort
                .send('Error: Server response was ${response.statusCode}');
          }
        } catch (e) {
          mainSendPort
              .send('Error downloading segment $startByte-$endByte: $e');
        }
      }
    });
  }

  Future<void> _checkFileIntegrity(String filePath, int expectedSize) async {
    final downloadedSize = await _getFileSizeFromPath(filePath);
    if (expectedSize == downloadedSize) {
      Utilities.debugPrint(
          'Download completed successfully: $filePath, Size: $downloadedSize bytes');
    } else {
      Utilities.debugPrint(
          'File corrupted: Expected size $expectedSize bytes, but got $downloadedSize bytes');
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
          Utilities.debugPrint('Segment file does not exist: $segmentFile');
          return;
        }

        await for (var data in segment.openRead()) {
          sink.add(data);
        }
        Utilities.debugPrint(
            'Merged segment file: $segmentFile into $outputFilePath');
      }
      Utilities.debugPrint('Merged file created at: ${outputFile.path}');
    } catch (e) {
      Utilities.debugPrint('Error merging file segments: $e');
      onError?.call(e.toString());
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
          Utilities.debugPrint('Deleted segment file: $segmentFile');
        }
      } catch (e) {
        Utilities.debugPrint(
            'Error deleting segment file: $segmentFile, Error: $e');
        onError?.call(e.toString());
      }
    }
  }

  Future<int> getFileSizeFromUrl(String url) async {
    return await _getFileSizeFromUrl(url);
  }

  Future<bool> _supportsRangeRequests(String url) async {
    try {
      final request = await HttpClient().headUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode == 200) {
        final acceptRanges = response.headers.value('Accept-Ranges');
        if (acceptRanges == 'bytes') {
          Utilities.debugPrint('Server supports resume capability.');
          return true;
        } else {
          Utilities.debugPrint('Server does not support resume capability.');
        }
      } else {
        Utilities.debugPrint(
            'Failed to check resume capability with status code: ${response.statusCode}');
      }
    } catch (e) {
      Utilities.debugPrint('Error while checking resume capability: $e');
      onError?.call(e.toString());
    }
    return false;
  }

  Future<void> _downloadSegmentedFixedIsolates(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();
    int bytesDownloaded = 0;

    List<String> segmentFiles = [];
    List<Map<String, int>> segmentRanges = [];
    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;
      segmentRanges.add({'startByte': startByte, 'endByte': endByte});

      final segmentFile =
          await Utilities.createFile(customDirectory, '${fileName}_part$i');
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
        maxRetries
      ]);
      isolates.add(isolate);

      port.listen((message) async {
        if (message is String && message.startsWith('Error')) {
          onError?.call("Segment Error");
          downloadFailed = true;
        } else if (message is Map<String, dynamic>) {
          bytesDownloaded += message['bytesDownloaded'] as int;
          final progress = (bytesDownloaded / totalSize) * 100;
          onProgress?.call(progress);
          Utilities.debugPrint('Progress: ${progress.toStringAsFixed(2)}%');

          if (bytesDownloaded >= totalSize) {
            Utilities.debugPrint('Download Complete!');
          }
        }
      });
    }

    while (bytesDownloaded < totalSize && !downloadFailed) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    if (downloadFailed) {
      Utilities.debugPrint('Download failed, cleaning up segment files.');
      await _cleanupSegmentFiles(segmentFiles);
      return;
    }

    await _mergeFileSegments(segmentFiles, filePath);
    await _checkFileIntegrity(filePath, totalSize);
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
    }
  }
}
