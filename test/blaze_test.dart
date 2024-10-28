import 'package:blaze_engine/blaze_downloader.dart';
import 'package:test/test.dart';

void main() {
  // Define the download link and file path
  final String url =
      'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf';
  test('Blaze should create an instance with URL and file path', () {
    final blaze = BlazeDownloader(
      url,
    );
    expect(blaze.url, url);
  });

  test('Blaze should download a file', () async {
    final blaze = BlazeDownloader(
      url,
      forceDownload: false,
    );
    await blaze.download();
  });
}
