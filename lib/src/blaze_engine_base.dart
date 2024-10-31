import 'dart:io';
import 'dart:async';
import 'dart:isolate';

import 'package:blaze_engine/src/download_segment.dart';
import 'package:hive/hive.dart';

bool isDebugModeEnabled = false;

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
    if (segmentCount <= 0 || workerCount <= 0) {
      throw Exception(
          'Segment count and worker count must be greater than zero.');
    }

    DateTime startTime = DateTime.now();
    _debugPrint("Download initiated at: ${startTime.toIso8601String()}");

    final fileName = _getFileNameFromUrl(downloadUrl);
    final filePath = await _createFile(fileName);
    _debugPrint("File name extracted: $fileName");
    _debugPrint("File will be saved at: $filePath");

    try {
      final totalSize = await _getFileSizeFromUrl(downloadUrl);
      if (totalSize == 0) {
        _debugPrint('Could not retrieve file size. Aborting download.');
        _debugPrint("Aborting download due to zero file size.");
        return;
      }
      _debugPrint("Total file size retrieved: $totalSize bytes");

      if (sequentialDownload) {
        _debugPrint("Sequential download mode enabled.");
        final canResume = await _supportsRangeRequests(downloadUrl);
        if (canResume) {
          _debugPrint("Server supports range requests. Resuming download...");
          await _downloadSequential(filePath, totalSize);
        } else {
          _debugPrint(
              'Resume capability not supported, downloading the entire file...');
          await _downloadSequential(filePath, totalSize);
        }
      } else {
        if (enableWorkerPooling) {
          _debugPrint("Pool queue mode enabled for segmented download.");
          await _downloadSegmentedWithWorkerPool(fileName, filePath, totalSize);
        } else {
          _debugPrint("Fixed isolates mode enabled for segmented download.");
          await _downloadSegmentedFixedIsolates(fileName, filePath, totalSize);
        }
      }
      onComplete?.call(filePath);
      DateTime endTime = DateTime.now();
      _debugPrint("Download completed at: ${endTime.toIso8601String()}");

      // Calculate the difference
      Duration difference = endTime.difference(startTime);

      // _debugPrint the difference in days, hours, minutes, and seconds
      _debugPrint("Download Duration:");
      _debugPrint("${difference.inDays} days");
      _debugPrint("${difference.inHours % 24} hours");
      _debugPrint("${difference.inMinutes % 60} minutes");
      _debugPrint("${difference.inSeconds % 60} seconds");
    } catch (e) {
      _debugPrint('Error during download: $e');
      onError?.call(e.toString());
      _debugPrint("An error occurred during the download process: $e");
    }
  }

  Future<void> _downloadSequential(String filePath, int totalSize) async {
    final file = File(filePath);
    int startByte = 0;

    if (allowResume && await file.exists()) {
      startByte = await _getFileSizeFromPath(filePath);
      if (startByte >= totalSize) {
        _debugPrint('File already downloaded: $filePath');
        return;
      }
      _debugPrint('Resuming download from byte: $startByte');
    } else {
      _debugPrint('Starting new download...');
    }

    final request = await HttpClient().getUrl(Uri.parse(downloadUrl));

    final endByte = totalSize - 1;
    request.headers.add('Range', 'bytes=$startByte-$endByte');

    final response = await request.close();

    if (response.statusCode == 206 || response.statusCode == 200) {
      // Initialize bytes downloaded for this session
      int bytesDownloaded = startByte;

      final fileSink = file.openWrite(mode: FileMode.append);

      await for (var data in response) {
        fileSink.add(data);
        bytesDownloaded += data.length;

        // Calculate progress
        final progress = (bytesDownloaded / totalSize) * 100;
        onProgress?.call(progress); // Update progress
        _debugPrint('Progress: ${progress.toStringAsFixed(2)}%');
      }

      await fileSink.close();
      await _checkFileIntegrity(filePath, totalSize);
    } else {
      _debugPrint('Download failed with status code: ${response.statusCode}');
    }
  }

  Future<String> _createFile(String fileName) async {
    final directory = Directory(customDirectory);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return '${directory.path}/$fileName';
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
        _debugPrint(
            'Failed to get file size with status code: ${response.statusCode}');
      }
    } catch (e) {
      _debugPrint('Error while getting file size: $e');
      onError?.call(e.toString());
    }
    return 0;
  }

  Future<Box> openBoxByFilename(String filename) async {
    return await Hive.openBox(filename);
  }

  Future<void> storeSegment(String filename, DownloadSegment segment) async {
    var box = await openBoxByFilename(filename);
    await box.put(segment.segmentIndex, {
      'startByte': segment.startByte,
      'endByte': segment.endByte,
      'totalDownloaded': segment.totalDownloaded,
      'status': segment.status,
    });
  }

  Future<List<DownloadSegment>> getAllSegments(String filename) async {
    var box = await openBoxByFilename(filename);
    List<DownloadSegment> segments = [];

    for (var key in box.keys) {
      var segmentData = box.get(key);
      segments.add(DownloadSegment(
        segmentIndex: key,
        startByte: segmentData['startByte'],
        endByte: segmentData['endByte'],
        totalDownloaded: segmentData['totalDownloaded'],
        status: segmentData['status'],
      ));
    }
    return segments;
  }

  Future<void> _downloadSegmentedWithWorkerPool(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();
    List<ReceivePort> workerReceivePorts = [];
    List<String> segmentFiles = [];
    List<Map<String, int>> downloadSegmentQueue = [];
    int bytesDownloaded = 0; // Track total bytes downloaded across segments

    Hive.init(customDirectory);
    openBoxByFilename(fileName);

    // Prepare segment queue and segment file paths
    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;
      downloadSegmentQueue.add({'startByte': startByte, 'endByte': endByte});

      // Create a segment file path
      final segmentFile = await _createFile('${fileName}_part$i');
      segmentFiles.add(segmentFile);

      storeSegment(
          fileName,
          DownloadSegment(
              segmentIndex: i,
              startByte: startByte,
              endByte: endByte,
              totalDownloaded: 0,
              status: "pending"));
    }

    // Retrieve and print all segments for the filename
    var segments = await getAllSegments(fileName);
    for (var seg in segments) {
      print('Segment Index: ${seg.segmentIndex}');
      print('Start Byte: ${seg.startByte}');
      print('End Byte: ${seg.endByte}');
      print('Total Downloaded: ${seg.totalDownloaded}');
      print('Status: ${seg.status}\n');
    }

    _debugPrint('Starting worker creation with $workerCount workers.');
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
          // Assign tasks to the worker
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
          // Update downloaded bytes and calculate progress
          bytesDownloaded += message['bytesDownloaded'] as int;
          final progress = (bytesDownloaded / totalSize) * 100;
          onProgress?.call(progress);
          _debugPrint('Progress: ${progress.toStringAsFixed(2)}%');

          if (bytesDownloaded >= totalSize) {
            _debugPrint('Download Complete!');
          }
        }
      });
    }

    // Wait for all segments to be processed
    while (bytesDownloaded < totalSize && !downloadFailed) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    if (downloadFailed) {
      _debugPrint('Download failed, cleaning up segment files.');
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
        _debugPrint('File does not exist: $filePath');
      }
    } catch (e) {
      _debugPrint('Error while getting file size: $e');
      onError?.call(e.toString());
    }
    return 0;
  }

  static void _workerMainForPoolQueue(List<dynamic> args) async {
    SendPort mainSendPort = args[0];

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

              // Send progress update to main isolate
              mainSendPort.send({'bytesDownloaded': data.length});
            }
            await fileSink.close();

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
      _debugPrint(
          'Download completed successfully: $filePath, Size: $downloadedSize bytes');
    } else {
      _debugPrint(
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
          _debugPrint('Segment file does not exist: $segmentFile');
          return;
        }

        await for (var data in segment.openRead()) {
          sink.add(data);
        }
        _debugPrint('Merged segment file: $segmentFile into $outputFilePath');
      }
      _debugPrint('Merged file created at: ${outputFile.path}');
    } catch (e) {
      _debugPrint('Error merging file segments: $e');
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
          _debugPrint('Deleted segment file: $segmentFile');
        }
      } catch (e) {
        _debugPrint('Error deleting segment file: $segmentFile, Error: $e');
        onError?.call(e.toString());
      }
    }
  }

  Future<int> getFileSizeFromUrl(String url) async {
    return await _getFileSizeFromUrl(url);
  }

  String _getFileNameFromUrl(String url) {
    return url.split('/').last; // Extract file name from URL
  }

  Future<bool> _supportsRangeRequests(String url) async {
    try {
      final request = await HttpClient().headUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode == 200) {
        final acceptRanges = response.headers.value('Accept-Ranges');
        if (acceptRanges == 'bytes') {
          _debugPrint('Server supports resume capability.');
          return true;
        } else {
          _debugPrint('Server does not support resume capability.');
        }
      } else {
        _debugPrint(
            'Failed to check resume capability with status code: ${response.statusCode}');
      }
    } catch (e) {
      _debugPrint('Error while checking resume capability: $e');
      onError?.call(e.toString());
    }
    return false;
  }

  Future<void> _downloadSegmentedFixedIsolates(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();
    int bytesDownloaded = 0; // Track total bytes downloaded across segments

    // Initialize segment files and define ranges
    List<String> segmentFiles = [];
    List<Map<String, int>> segmentRanges = [];
    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;
      segmentRanges.add({'startByte': startByte, 'endByte': endByte});

      // Create a segment file path
      final segmentFile = await _createFile('${fileName}_part$i');
      segmentFiles.add(segmentFile);
    }

    // Set up communication ports
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

      // Listen for messages from each isolate
      port.listen((message) async {
        if (message is String && message.startsWith('Error')) {
          // Handle segment download failure
          onError?.call("Segment Error");
          downloadFailed = true;
        } else if (message is Map<String, dynamic>) {
          // Update downloaded bytes
          bytesDownloaded += message['bytesDownloaded'] as int;
          final progress = (bytesDownloaded / totalSize) * 100;
          onProgress?.call(progress);
          _debugPrint('Progress: ${progress.toStringAsFixed(2)}%');

          // Check if all bytes are downloaded
          if (bytesDownloaded >= totalSize) {
            _debugPrint('Download Complete!');
          }
        }
      });
    }

    // Wait for all segments to be processed
    while (bytesDownloaded < totalSize && !downloadFailed) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    if (downloadFailed) {
      _debugPrint('Download failed, cleaning up segment files.');
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

          // Send progress update to main isolate
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

  void _debugPrint(String message) {
    if (isDebugModeEnabled) {
      print(message);
    }
  }
}
