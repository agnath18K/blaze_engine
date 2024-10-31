class DownloadSegment {
  final int segmentIndex;
  final int startByte;
  final int endByte;
  final int totalDownloaded;
  final String status;

  DownloadSegment({
    required this.segmentIndex,
    required this.startByte,
    required this.endByte,
    required this.totalDownloaded,
    required this.status,
  });
}
