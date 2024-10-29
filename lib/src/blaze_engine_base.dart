import 'dart:io';
import 'dart:async';
import 'dart:isolate';

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

    if (response.statusCode == 206) {
      await response.pipe(file.openWrite(mode: FileMode.append));
      await _checkFileIntegrity(filePath, totalSize);
    } else if (response.statusCode == 200) {
      _debugPrint(
          'Server does not support range requests. Downloading the entire file...');
      await response.pipe(file.openWrite());
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

  Future<void> _downloadSegmentedWithWorkerPool(
      String fileName, String filePath, int totalSize) async {
    final segmentSize = (totalSize / segmentCount).ceil();
    List<ReceivePort> workerReceivePorts = [];
    List<String> segmentFiles = [];
    List<Map<String, int>> downloadSegmentQueue = [];
    int completedSegments = 0;
    final totalSegments = segmentCount;

    // Prepare segment queue and segment file paths
    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte =
          (i == segmentCount - 1) ? totalSize - 1 : startByte + segmentSize - 1;
      downloadSegmentQueue.add({'startByte': startByte, 'endByte': endByte});

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
      workerReceivePorts.add(port);

      final worker =
          await Isolate.spawn(_workerMainForPoolQueue, [port.sendPort, this]);
      workers.add(worker);

      port.listen((message) async {
        if (message is SendPort) {
          // Send initial tasks to the worker
          while (downloadSegmentQueue.isNotEmpty) {
            final task = downloadSegmentQueue.removeAt(0);
            _debugPrint(
                'Sending task to worker: Start Byte: ${task['startByte']}, End Byte: ${task['endByte']}');
            message.send([
              task['startByte'],
              task['endByte'],
              downloadUrl,
              segmentFiles[
                  segmentFiles.length - downloadSegmentQueue.length - 1],
              maxRetries // Pass max retries to worker
            ]);
          }
        } else if (message is String && message.startsWith('Error')) {
          onError?.call("Segment Error");
          downloadFailed = true;
          _debugPrint(message); // Log error
        } else {
          _debugPrint(message); // Log success message
          // Increment the completed segment counter
          completedSegments++;
          // Update and _debugPrint download progress
          _printProgress(completedSegments, totalSegments);
          // Check if all segments are completed
          if (completedSegments == totalSegments) {
            _debugPrint('All segments downloaded successfully.');
            // Send a message to all workers to terminate
            for (var port in workerReceivePorts) {
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
      onError?.call(e.toString());
    }
    return 0;
  }

  static void _workerMainForPoolQueue(List<dynamic> args) async {
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

  void _printProgress(int completedSegments, int totalSegments) {
    final progress = (completedSegments / totalSegments) * 100;
    onProgress?.call(progress);
    const barLength = 40;
    final filledLength = (progress / 100 * barLength).round();
    final bar = '=' * filledLength + '-' * (barLength - filledLength);

    stdout.write('\r[$bar] ${progress.toStringAsFixed(2)}% Complete');

    if (progress >= 100) {
      _debugPrint('\nDownload Complete!');
    }
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
    final segmentSize =
        (totalSize / segmentCount).ceil(); // Divide into specified segments
    List<ReceivePort> ports = [];
    List<String> segmentFiles =
        []; // List to hold paths of downloaded segment files
    bool downloadFailed = false;

    // Create and spawn isolates for downloading segments
    for (int i = 0; i < segmentCount; i++) {
      final startByte = i * segmentSize;
      final endByte = (i == segmentCount - 1)
          ? totalSize - 1
          : startByte + segmentSize - 1; // last segment takes remaining bytes

      final port = ReceivePort();
      ports.add(port);

      // Create a temporary file for each segment
      final segmentFile = await _createFile('${fileName}_part$i');
      segmentFiles.add(segmentFile);

      // Spawn an isolate for downloading each segment
      await Isolate.spawn(_downloadSegmentFixedIsolates,
          [port.sendPort, downloadUrl, segmentFile, startByte, endByte]);

      _debugPrint('Downloading segment:');
      _debugPrint('URL: $downloadUrl');
      _debugPrint('Segment file path: $segmentFile');
      _debugPrint('Start byte: $startByte');
      _debugPrint('End byte: $endByte');
    }

    // Wait for all segments to be downloaded
    for (var port in ports) {
      final result = await port.first;
      if (result is String && result.startsWith('Error')) {
        onError?.call("Segment download error");
        downloadFailed = true;
      }
    }

    if (downloadFailed) {
      _debugPrint('Download failed, cleaning up segment files.');
      await _cleanupSegmentFiles(segmentFiles);
      return;
    }

    // Merge the downloaded segments into a single output file
    await _mergeFileSegments(segmentFiles, filePath);

    // Check integrity of the merged file
    await _checkFileIntegrity(filePath, totalSize);

    // Cleanup segment files after successful merge
    await _cleanupSegmentFiles(segmentFiles);
  }

  static Future<void> _downloadSegmentFixedIsolates(List<dynamic> args) async {
    final SendPort sendPort = args[0];
    final String url = args[1];
    final String segmentFilePath = args[2];
    final int startByte = args[3];
    final int endByte = args[4];

    try {
      final request = await HttpClient().getUrl(Uri.parse(url));
      request.headers.add('Range', 'bytes=$startByte-$endByte');

      final response = await request.close();

      if (response.statusCode == 206 || response.statusCode == 200) {
        final file = File(segmentFilePath);

        // Write the received bytes to the segment file
        await response.pipe(file.openWrite());

        // Notify the main isolate that this segment has been downloaded
        sendPort.send('Segment $startByte-$endByte downloaded successfully.');
      } else {
        sendPort.send(
            'Download failed with status code: ${response.statusCode} for segment $startByte-$endByte');
      }
    } catch (e) {
      print('Error downloading segment: $e');

      sendPort.send('Error downloading segment $startByte-$endByte: $e');
    }
  }

  void _debugPrint(String message) {
    if (isDebugModeEnabled) {
      print(message);
    }
  }
}
