import 'package:blaze_engine/blaze_engine.dart';
import 'package:test/test.dart';

void main() {
  test('Download file from URL', () async {
    final downloader = BlazeDownloader(
        downloadUrl:
            'https://releases.ubuntu.com/14.04.6/ubuntu-14.04.6-server-amd64.template',
        customDirectory: 'download');
    await downloader.startDownload();
  });
}
