import 'package:blaze_engine/src/segmented_controlled.dart';

void main() {
  final sequentialDownload = SegmentControlled(
    segmentCount: 8,
    workerCount: 4,
    downloadUrl:
        'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-desktop-amd64.iso.zsync',
    destinationPath: 'Downloads',
    onProgress: (progress) => print('Progress: $progress%'),
    onComplete: (filePath) => print('Download completed: $filePath'),
    onError: (error) => print('Error: $error'),
  );
  sequentialDownload.startDownload();
}
