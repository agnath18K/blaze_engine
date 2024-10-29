import 'dart:io';
import 'dart:async';
import 'dart:isolate';

bool isDebugModeEnabled = false;

class BlazeDownloader {
  final String downloadUrl;
  final String customDirectory;
  final int segmentCount;
  final int workerCount;
  final int maxRetries; // Maximum retries for failed downloads

  BlazeDownloader({
    required this.downloadUrl,
    required this.customDirectory,
    this.segmentCount = 20,
    this.workerCount = 4,
    this.maxRetries = 3, // Default to 3 retries
  });

  Future<void> startDownload() async {
    DateTime startTime = DateTime.now();
    print("Start Time : ${DateTime.now()}");
    final fileName = _getFileNameFromUrl(downloadUrl);
    final filePath = await _createFile(fileName);

    try {
      final totalSize = await _getFileSizeFromUrl(downloadUrl);
      if (totalSize == 0) {
        _debugPrint('Could not retrieve file size. Aborting download.');
        return;
      }

      await _downloadSegmentedFile(fileName, filePath, totalSize);
      DateTime endTime = DateTime.now();
      print("End Time : ${DateTime.now()}");

      // Calculate the difference
      Duration difference = endTime.difference(startTime);

      // Print the difference in days, hours, minutes, and seconds
      print("Difference:");
      print("${difference.inDays} days");
      print("${difference.inHours % 24} hours");
      print("${difference.inMinutes % 60} minutes");
      print("${difference.inSeconds % 60} seconds");
    } catch (e) {
      _debugPrint('Error during download: $e');
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
    }
    return 0;
  }

  Future<void> _downloadSegmentedFile(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();
    List<ReceivePort> ports = [];
    List<String> segmentFiles = [];
    List<Map<String, int>> segmentQueue = [];
    int completedSegments = 0;
    final totalSegments = segmentCount;

    // Prepare segment queue and segment file paths
    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;
      segmentQueue.add({'startByte': startByte, 'endByte': endByte});

      // Create a segment file path
      final segmentFile = await _createFile('${fileName}_part$i');
      segmentFiles.add(segmentFile);
      _debugPrint('Created segment file: $segmentFile'); // Debugging output
    }

    _debugPrint('Starting worker creation with $workerCount workers.');
    bool downloadFailed = false;
    List<Isolate> workers = [];

    // Spawn workers and assign tasks
    for (int i = 0; i < workerCount; i++) {
      final port = ReceivePort();
      ports.add(port);

      final worker = await Isolate.spawn(_workerMain, [port.sendPort, this]);
      workers.add(worker);

      port.listen((message) async {
        if (message is SendPort) {
          // Send initial tasks to the worker
          while (segmentQueue.isNotEmpty) {
            final task = segmentQueue.removeAt(0);
            _debugPrint(
                'Sending task to worker: Start Byte: ${task['startByte']}, End Byte: ${task['endByte']}');
            message.send([
              task['startByte'],
              task['endByte'],
              downloadUrl,
              segmentFiles[segmentFiles.length - segmentQueue.length - 1],
              maxRetries // Pass max retries to worker
            ]);
          }
        } else if (message is String && message.startsWith('Error')) {
          downloadFailed = true;
          _debugPrint(message); // Log error
        } else {
          _debugPrint(message); // Log success message
          // Increment the completed segment counter
          completedSegments++;
          // Update and print download progress
          _printProgress(completedSegments, totalSegments);
          // Check if all segments are completed
          if (completedSegments == totalSegments) {
            _debugPrint('All segments downloaded successfully.');
            // Send a message to all workers to terminate
            for (var port in ports) {
              port.close(); // Close the port to signal no more messages
            }
          }
        }
      });
    }

    // Wait for all workers to finish processing segments
    while (completedSegments < totalSegments) {
      await Future.delayed(
          Duration(milliseconds: 100)); // Wait until all segments are processed
    }

    if (downloadFailed) {
      _debugPrint('Download failed, cleaning up segment files.');
      await _cleanupSegmentFiles(segmentFiles);
      return;
    }

    for (int i = 0; i < segmentFiles.length; i++) {
      final fileSize = await _getFileSizeFromPath(segmentFiles[i]);
      _debugPrint(
          'Segment File: ${segmentFiles[i]}, Size: $fileSize bytes'); // Debugging output
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
    }
    return 0;
  }

  static void _workerMain(List<dynamic> args) async {
    SendPort mainSendPort = args[0];
    BlazeDownloader downloader = args[1]; // Access the downloader instance

    ReceivePort workerReceivePort = ReceivePort();

    // Send worker's own SendPort to the main isolate
    mainSendPort.send(workerReceivePort.sendPort);

    workerReceivePort.listen((message) async {
      if (message is List<dynamic>) {
        final startByte = message[0];
        final endByte = message[1];
        final downloadUrl = message[2];
        final segmentFilePath = message[3];
        final maxRetries = message[4]; // Get max retries

        downloader._debugPrint(
            'Worker received task: Start Byte: $startByte, End Byte: $endByte');
        final result = await downloader._downloadSegment(
            startByte, endByte, downloadUrl, segmentFilePath, maxRetries);

        // Send result back to main isolate
        mainSendPort.send(result);
      }
    });
  }

  Future<String> _downloadSegment(int startByte, int endByte, String url,
      String segmentFilePath, int maxRetries) async {
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        final request = await HttpClient().getUrl(Uri.parse(url));
        request.headers.add('Range', 'bytes=$startByte-$endByte');
        final response = await request.close();

        if (response.statusCode == 206) {
          _debugPrint('Downloading segment $startByte-$endByte'); // Debugging
          final file = File(segmentFilePath);
          final fileSink = file.openWrite();

          int byteCount = 0;
          await for (var data in response) {
            fileSink.add(data);
            byteCount += data.length;
          }

          await fileSink.close();
          _debugPrint('Downloaded $byteCount bytes to $segmentFilePath');
          return 'Segment $startByte-$endByte downloaded successfully.';
        } else {
          attempt++;
          _debugPrint(
              'Attempt $attempt failed: Server did not support partial content (status: ${response.statusCode}) for range $startByte-$endByte');
        }
      } catch (e) {
        attempt++;
        _debugPrint(
            'Attempt $attempt failed downloading segment $startByte-$endByte: $e');
      }
    }

    return 'Error downloading segment $startByte-$endByte after $maxRetries attempts.';
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
      }
    }
  }

  void _printProgress(int completedSegments, int totalSegments) {
    final progress = (completedSegments / totalSegments) * 100;
    const barLength = 40;
    final filledLength = (progress / 100 * barLength).round();
    final bar = '=' * filledLength + '-' * (barLength - filledLength);

    stdout.write('\r[$bar] ${progress.toStringAsFixed(2)}% Complete');

    if (progress >= 100) {
      print('\nDownload Complete!');
    }
  }

  String _getFileNameFromUrl(String url) {
    return url.split('/').last; // Extract file name from URL
  }

  void _debugPrint(String message) {
    if (isDebugModeEnabled) {
      print(message);
    }
  }
}