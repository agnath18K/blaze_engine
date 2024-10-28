import 'dart:io';
import 'package:blaze_engine/blaze_downloader.dart';

void main() async {
  // Define the download URL and local file path
  final String url =
      'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf';
  final String filePath = 'dummy.pdf';

  // Create an instance of BlazeDownloader with callbacks
  final blaze = BlazeDownloader(
    url,

    maxRetries: 5,
    retryDuration: Duration(milliseconds: 100),
    forceDownload:
        true, // Set to true if you want to re-download even if the file exists
    onProgress: (downloadedBytes, totalBytes) {
      final progress = (downloadedBytes / totalBytes) * 100;
      print('Progress: ${progress.toStringAsFixed(2)}%');
    },
    onStatusChange: (status) {
      print('Status: $status');
    },
    onDownloadComplete: () {
      print('Download complete: $filePath');
    },
  );

  print('Starting download from $url...');

  // Start the download
  await blaze.download();

  // Check if the file was successfully downloaded
  final file = File(filePath);
  if (await file.exists()) {
    print('File downloaded successfully to $filePath.');
  } else {
    print('Failed to download the file.');
  }

  // Optionally, read and display file size
  if (await file.exists()) {
    final fileSize = await file.length();
    print('Downloaded file size: $fileSize bytes');
  }

  // Cleanup: Delete the downloaded file (optional)
  await file.delete();
  print('Downloaded file deleted.');
}
