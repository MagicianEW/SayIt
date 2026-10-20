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

    // 界面是固定布局（输入区 + 参数区 + 列表区），窗口再矮就会挤爆。
    // 限定最小尺寸，用户拖不到更小。默认尺寸在 MainMenu.xib 里
    // （contentRect 1024x700），awakeFromNib 里改不动 —— nib 加载完
    // 会用 xib 的 rect 再覆盖一次。
    self.minSize = NSSize(width: 780, height: 760)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
