import 'package:blaze_engine/blaze_engine.dart';
import 'package:test/test.dart';

void main() {
  test('Download file from URL', () async {
    final downloader = BlazeDownloader(
        downloadUrl:
            'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso.zsync',
        customDirectory: 'download');
    await downloader.startDownload();
  });
}
