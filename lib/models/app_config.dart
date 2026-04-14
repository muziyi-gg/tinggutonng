/// AppConfig - Phase 1 纯内存存储，无需持久化
class AppConfig {
  int reportIntervalSec;
  bool ttsEnabled;

  AppConfig({
    this.reportIntervalSec = 60,
    this.ttsEnabled = true,
  });
}
