import 'package:blaze_engine/blaze_engine.dart';
import 'package:test/test.dart';

void main() {
  test('Download file from URL', () async {
    final downloader = BlazeDownloader(
        downloadUrl:
            'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf',
        customDirectory: 'download');
    await downloader.startDownload();
  });
}
