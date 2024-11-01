enum LogLevel { debug, info, warning, error }

class Logger {
  final LogLevel logLevel;

  Logger({this.logLevel = LogLevel.debug});

  void log(LogLevel level, String message) {
    if (_shouldLog(level)) {
      final timestamp = DateTime.now().toIso8601String();
      final logMessage =
          '[$timestamp] [${level.toString().split('.').last.toUpperCase()}] $message';
      print(logMessage);
    }
  }

  void debug(String message) => log(LogLevel.debug, message);
  void info(String message) => log(LogLevel.info, message);
  void warning(String message) => log(LogLevel.warning, message);
  void error(String message) => log(LogLevel.error, message);

  bool _shouldLog(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return logLevel == LogLevel.debug;
      case LogLevel.info:
        return logLevel.index <= LogLevel.info.index;
      case LogLevel.warning:
        return logLevel.index <= LogLevel.warning.index;
      case LogLevel.error:
        return true; 
      default:
        return false;
    }
  }
}
