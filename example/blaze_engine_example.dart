import 'package:blaze_engine/blaze_engine.dart';

void main() async {
  final downloader = BlazeDownloader(
      downloadUrl:
          'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-desktop-amd64.iso',
      customDirectory: 'download');
  await downloader.startDownload();
}
