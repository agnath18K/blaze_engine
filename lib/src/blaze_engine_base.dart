class BlazeDownloader {
  final String downloadUrl;
  final String directoryPath;
  final bool useSegmentedDownload;
  final bool enableWorkerPooling;
  final int segmentCount;
  final int workerCount;
  final void Function(double progress)? onProgress;
  final void Function(String filePath)? onComplete;
  final void Function(String error)? onError;

  BlazeDownloader({
    required this.downloadUrl,
    required this.directoryPath,
    this.useSegmentedDownload = false,
    this.enableWorkerPooling = false,
    this.segmentCount = 8,
    this.workerCount = 4,
    this.onProgress,
    this.onComplete,
    this.onError,
  });
}
