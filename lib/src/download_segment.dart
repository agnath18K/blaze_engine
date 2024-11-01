class DownloadSegment {
  final int segmentIndex;
  final int startByte;
  final int endByte;
  final String segmentFilePath;
  final String status;

  DownloadSegment({
    required this.segmentIndex,
    required this.startByte,
    required this.endByte,
    required this.segmentFilePath,
    required this.status,
  });
}
