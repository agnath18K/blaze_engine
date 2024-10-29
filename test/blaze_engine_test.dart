import 'dart:io';
import 'package:blaze_engine/blaze_engine.dart';
import 'package:test/test.dart';

void main() {
  final String downloadDirectory = 'download';

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

  Future<void> verifyDownload(BlazeDownloader downloader, String downloadUrl,
      String expectedFileName) async {
    final String downloadedFilePath = '$downloadDirectory/$expectedFileName';

    // Check if the downloaded file exists
    expect(File(downloadedFilePath).existsSync(), isTrue,
        reason: 'Downloaded file should exist at: $downloadedFilePath');

    // Check the integrity of the downloaded file
    final int expectedFileSize =
        await downloader.getFileSizeFromUrl(downloadUrl);
    final int actualFileSize = await File(downloadedFilePath).length();
    expect(actualFileSize, equals(expectedFileSize),
        reason:
            'Downloaded file size ($actualFileSize) should match expected size ($expectedFileSize).');
  }

  test('Standard Download Test', () async {
    final String downloadUrl =
        'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso.zsync';
    final String expectedFileName =
        'ubuntu-22.04.5-live-server-amd64.iso.zsync';

    final BlazeDownloader downloader = BlazeDownloader(
      downloadUrl: downloadUrl,
      customDirectory: downloadDirectory,
      allowResume: false, // Resume is disabled
      sequentialDownload: true, // Sequential download is enabled
      enableWorkerPooling: false, // Worker pooling is disabled
      segmentCount: 1, // Only one segment for sequential download
      workerCount: 1, // Only one worker for sequential download
      maxRetries: 3,
    );

    // Start the download
    await downloader.startDownload();

    // Verify the download
    await verifyDownload(downloader, downloadUrl, expectedFileName);
  });

  test('Segmented Download with Worker Pooling Enabled', () async {
    final String downloadUrl =
        'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso.zsync';
    final String expectedFileName =
        'ubuntu-22.04.5-live-server-amd64.iso.zsync';

    final BlazeDownloader downloader = BlazeDownloader(
      downloadUrl: downloadUrl,
      customDirectory: downloadDirectory,
      allowResume: false, // Resume is disabled
      sequentialDownload: false, // Sequential download is disabled
      enableWorkerPooling: true, // Worker pooling is enabled
      segmentCount: 1, // Only one segment
      workerCount: 1, // Only one worker
      maxRetries: 3,
    );

    // Start the download
    await downloader.startDownload();

    // Verify the download
    await verifyDownload(downloader, downloadUrl, expectedFileName);
  });

  test('Segmented Download with Fixed Isolates', () async {
    final String downloadUrl =
        'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso.zsync';
    final String expectedFileName =
        'ubuntu-22.04.5-live-server-amd64.iso.zsync';

    final BlazeDownloader downloader = BlazeDownloader(
      downloadUrl: downloadUrl,
      customDirectory: downloadDirectory,
      allowResume: false, // Resume is disabled
      sequentialDownload: false, // Sequential download is disabled
      enableWorkerPooling: false, // Worker pooling is disabled
      segmentCount: 1, // Only one segment
      workerCount: 1, // Only one worker
      maxRetries: 3,
    );

    // Start the download
    await downloader.startDownload();

    // Verify the download
    await verifyDownload(downloader, downloadUrl, expectedFileName);
  });
}
