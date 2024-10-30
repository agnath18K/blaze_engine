import 'dart:io';
import 'package:blaze_engine/blaze_engine.dart';
import 'package:test/test.dart';

void main() {
  final String downloadDirectory = 'download';

  // List of dummy files with various sizes
  final List<Map<String, String>> testFiles = [
    {
      'url':
          'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-desktop-amd64.iso.zsync',
      'filename': 'ubuntu-22.04.5-desktop-amd64.iso.zsync'
    },
    {
      'url':
          'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso.zsync',
      'filename': 'ubuntu-22.04.5-live-server-amd64.iso.zsync'
    },
  ];

  final List<Map<String, int>> combinations = [
    {'workerCount': 1, 'segmentCount': 1},
    {'workerCount': 2, 'segmentCount': 4},
    {'workerCount': 4, 'segmentCount': 8},
    {'workerCount': 8, 'segmentCount': 16},
  ];

  setUp(() async {
    // Create the download directory before each test
    if (!Directory(downloadDirectory).existsSync()) {
      await Directory(downloadDirectory).create();
    }
  });

  tearDown(() async {
    // Clean up the download directory after each test
    final Directory dir = Directory(downloadDirectory);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Future<void> verifyDownload(
      BlazeDownloader downloader, String expectedFilePath) async {
    // Check if the downloaded file exists
    expect(File(expectedFilePath).existsSync(), isTrue,
        reason: 'Downloaded file should exist at: $expectedFilePath');

    // Check the integrity of the downloaded file
    final int expectedFileSize =
        await downloader.getFileSizeFromUrl(downloader.downloadUrl);
    final int actualFileSize = await File(expectedFilePath).length();
    expect(actualFileSize, equals(expectedFileSize),
        reason:
            'Downloaded file size ($actualFileSize) should match expected size ($expectedFileSize).');
  }

  void printProgressBar(double progress, String filename) {
    final int barWidth = 40;
    final int completed = (progress / 100 * barWidth).round();
    final int remaining = barWidth - completed;

    // Building the progress bar string
    final String bar = '[' +
        ('#' * completed) +
        ('-' * remaining) +
        '] ${(progress).toStringAsFixed(2)}%';

    stdout.write('\rDownloading $filename $bar');
    if (progress >= 100.0) {
      stdout.write('\n'); // Move to the next line on completion
    }
  }

  for (var testFile in testFiles) {
    final String downloadUrl = testFile['url']!;
    final String expectedFileName = testFile['filename']!;
    final String expectedFilePath = '$downloadDirectory/$expectedFileName';

    test(
        'Standard Download Test for $expectedFileName with Sequential Download',
        () async {
      final Stopwatch stopwatch = Stopwatch()..start();

      final BlazeDownloader downloader = BlazeDownloader(
        downloadUrl: downloadUrl,
        customDirectory: downloadDirectory,
        allowResume: false,
        sequentialDownload: true,
        enableWorkerPooling: false,
        segmentCount: 8,
        workerCount: 4,
        maxRetries: 3,
        onProgress: (progress) {
          printProgressBar(progress, expectedFileName);
        },
      );

      await downloader.startDownload();
      await verifyDownload(downloader, expectedFilePath);

      stopwatch.stop();
      final int fileSize = await File(expectedFilePath).length();
      final double transferSpeed =
          fileSize / stopwatch.elapsed.inSeconds / (1024 * 1024); // MB/s

      print('\n--- Standard Download Test Results ---');
      print('File: $expectedFileName');
      print('Time taken: ${stopwatch.elapsed}');
      print('Average transfer speed: ${transferSpeed.toStringAsFixed(2)} MB/s\n');
    });

    test(
        'Segmented Download Test for $expectedFileName with Worker Pooling Enabled',
        () async {
      final Stopwatch stopwatch = Stopwatch()..start();

      final BlazeDownloader downloader = BlazeDownloader(
        downloadUrl: downloadUrl,
        customDirectory: downloadDirectory,
        allowResume: false,
        sequentialDownload: false,
        enableWorkerPooling: true,
        segmentCount: 8,
        workerCount: 4,
        maxRetries: 3,
        onProgress: (progress) {
          printProgressBar(progress, expectedFileName);
        },
      );

      await downloader.startDownload();
      await verifyDownload(downloader, expectedFilePath);

      stopwatch.stop();
      final int fileSize = await File(expectedFilePath).length();
      final double transferSpeed =
          fileSize / stopwatch.elapsed.inSeconds / (1024 * 1024); // MB/s

      print('\n--- Segmented Download Test Results ---');
      print('File: $expectedFileName');
      print('Time taken: ${stopwatch.elapsed}');
      print('Average transfer speed: ${transferSpeed.toStringAsFixed(2)} MB/s\n');
    });

    test('Segmented Download for $expectedFileName with Fixed Isolates',
        () async {
      final Stopwatch stopwatch = Stopwatch()..start();

      final BlazeDownloader downloader = BlazeDownloader(
        downloadUrl: downloadUrl,
        customDirectory: downloadDirectory,
        allowResume: false,
        sequentialDownload: false,
        enableWorkerPooling: false,
        segmentCount: 8,
        workerCount: 4,
        maxRetries: 3,
        onProgress: (progress) {
          printProgressBar(progress, expectedFileName);
        },
      );

      await downloader.startDownload();
      await verifyDownload(downloader, expectedFilePath);

      stopwatch.stop();
      final int fileSize = await File(expectedFilePath).length();
      final double transferSpeed =
          fileSize / stopwatch.elapsed.inSeconds / (1024 * 1024); // MB/s

      print('\n--- Segmented Download Test Results ---');
      print('File: $expectedFileName');
      print('Time taken: ${stopwatch.elapsed}');
      print('Average transfer speed: ${transferSpeed.toStringAsFixed(2)} MB/s\n');
    });

    String bestConfig = '';
    Duration bestTime = Duration(days: 365);

    for (var combo in combinations) {
      final int workerCount = combo['workerCount']!;
      final int segmentCount = combo['segmentCount']!;

      test(
          'Download Test for $expectedFileName with Worker Count: $workerCount and Segment Count: $segmentCount',
          () async {
        final Stopwatch stopwatch = Stopwatch()..start();

        final BlazeDownloader downloader = BlazeDownloader(
          downloadUrl: downloadUrl,
          customDirectory: downloadDirectory,
          allowResume: false,
          sequentialDownload: false,
          enableWorkerPooling: true,
          segmentCount: segmentCount,
          workerCount: workerCount,
          maxRetries: 3,
          onProgress: (progress) {
            printProgressBar(progress, expectedFileName);
          },
        );

        await downloader.startDownload();
        await verifyDownload(downloader, expectedFilePath);

        stopwatch.stop();
        final int fileSize = await File(expectedFilePath).length();
        final double transferSpeed =
            fileSize / stopwatch.elapsed.inSeconds / (1024 * 1024); // MB/s

        print('\n--- Download Test Results ---');
        print('File: $expectedFileName');
        print('Worker Count: $workerCount');
        print('Segment Count: $segmentCount');
        print('Time taken: ${stopwatch.elapsed}');
        print('Average transfer speed: ${transferSpeed.toStringAsFixed(2)} MB/s\n');

        if (stopwatch.elapsed < bestTime) {
          bestTime = stopwatch.elapsed;
          bestConfig =
              'Worker Count: $workerCount, Segment Count: $segmentCount';
        }
      });
    }

    tearDownAll(() {
      print('\n--- Best Configuration Results ---');
      print('Best configuration for $expectedFileName: $bestConfig with time: $bestTime');
    });
  }
}
