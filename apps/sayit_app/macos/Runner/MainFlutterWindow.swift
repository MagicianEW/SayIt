import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 窗口标题用中文显示名。xib 里的 APP_NAME 是模板占位符，本项目里它
    // 从未被替换，所以这里显式覆盖一次。名字的单一来源是
    // scripts/sync_app_name.py，改名请改那里再跑脚本。
    self.title = "说吧"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
