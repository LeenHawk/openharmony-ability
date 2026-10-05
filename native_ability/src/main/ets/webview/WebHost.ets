import { UIContext } from "@ohos.arkui.UIContext";
import { ComponentContent } from "@ohos.arkui.node";
import webview from "@ohos.web.webview";
import window from "@ohos.window";
import common from "@ohos.app.ability.common";
import picker from "@ohos.file.picker";

class PromptData {
  constructor(
    public message: string,
    public value: string,
    public finish: (value?: string) => void,
  ) {}
}

@Component
struct WebPrompt {
  data: PromptData;
  @State value: string = "";

  aboutToAppear(): void {
    this.value = this.data.value;
  }

  build() {
    Column({ space: 16 }) {
      Text(this.data.message)
      TextInput({ text: this.value })
        .onChange((value: string) => {
          this.value = value;
        })
      Row({ space: 16 }) {
        Button($r("app.string.web_dialog_cancel"))
          .onClick(() => this.data.finish())
        Button($r("app.string.web_dialog_ok"))
          .onClick(() => this.data.finish(this.value))
      }
    }
    .padding(24)
    .backgroundColor(Color.White)
    .borderRadius(16);
  }
}

@Builder
function promptBuilder(data: PromptData) {
  WebPrompt({ data });
}

// Browser UI stays in the native host, independently of application frontend code.
export class WebHost {
  private static active?: WebHost;
  private static backScript: string = "";
  private static unhandledBack?: () => void;
  private fullscreen?: FullScreenExitHandler;
  private previousFullscreen: boolean = false;
  private handlingBack: boolean = false;

  constructor(
    private ui: UIContext,
    private controller: webview.WebviewController,
  ) {
    WebHost.active = this;
  }

  activate(): void {
    WebHost.active = this;
  }

  dispose(): void {
    if (WebHost.active === this) WebHost.active = undefined;
  }

  static configureBackNavigation(script: string, onUnhandled?: () => void): void {
    WebHost.backScript = script;
    WebHost.unhandledBack = onUnhandled;
  }

  static handleBackPress(): boolean {
    const host = WebHost.active;
    if (!host) return false;
    if (host.fullscreen) {
      host.fullscreen.exitFullScreen();
      return true;
    }
    if (!WebHost.backScript) return false;
    if (host.handlingBack) return true;
    host.handlingBack = true;
    host.controller
      .runJavaScript(WebHost.backScript)
      .then((value: string) => {
        if (WebHost.active === host && value !== "true") WebHost.unhandledBack?.();
      })
      .catch((error: Error) => {
        console.error(`Unable to dispatch WebView back navigation: ${error.message}`);
        if (WebHost.active === host) WebHost.unhandledBack?.();
      })
      .finally(() => {
        host.handlingBack = false;
      });
    return true;
  }

  /** Runs a script in the active webview's main frame, the same target as back navigation. */
  static async runJavaScript(script: string): Promise<string> {
    const host = WebHost.active;
    if (!host) throw new Error("No active webview");
    return host.controller.runJavaScript(script);
  }

  async enterFullscreen(handler: FullScreenExitHandler): Promise<void> {
    const context = this.ui.getHostContext() as common.UIAbilityContext;
    try {
      const win = await window.getLastWindow(context);
      this.previousFullscreen = win.getWindowProperties().isLayoutFullScreen;
      await win.setWindowLayoutFullScreen(true);
      this.fullscreen = handler;
    } catch (_) {
      handler.exitFullScreen();
    }
  }

  async exitFullscreen(): Promise<void> {
    if (!this.fullscreen) return;
    this.fullscreen = undefined;
    const context = this.ui.getHostContext() as common.UIAbilityContext;
    const win = await window.getLastWindow(context);
    await win.setWindowLayoutFullScreen(this.previousFullscreen);
  }

  async selectFiles(event: OnShowFileSelectorEvent): Promise<void> {
    const context = this.ui.getHostContext() as common.UIAbilityContext;
    const mode = event.fileSelector.getMode();
    if (mode !== FileSelectorMode.FileOpenMode && mode !== FileSelectorMode.FileOpenMultipleMode) {
      event.result.handleFileList([]);
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = {
        maxSelectNumber: mode === FileSelectorMode.FileOpenMultipleMode ? 500 : 1,
      };
      const extensions = event.fileSelector
        .getAcceptType()
        .filter((value: string) => value.startsWith("."));
      if (extensions.length > 0) options.fileSuffixFilters = [`Files|${extensions.join(",")}`];
      const files = await new picker.DocumentViewPicker(context).select(options);
      event.result.handleFileList(files);
    } catch (_) {
      event.result.handleFileList([]);
    }
  }

  async dialog(message: string, result: JsResult, confirm: boolean): Promise<void> {
    try {
      const buttons = confirm
        ? [
            { text: $r("app.string.web_dialog_cancel"), color: "#182431" },
            { text: $r("app.string.web_dialog_ok"), color: "#007DFF" },
          ]
        : [{ text: $r("app.string.web_dialog_ok"), color: "#007DFF" }];
      const response = await this.ui.getPromptAction().showDialog({ message, buttons });
      if (response.index === (confirm ? 1 : 0)) result.handleConfirm();
      else result.handleCancel();
    } catch (_) {
      result.handleCancel();
    }
  }

  prompt(event: OnPromptEvent): void {
    const prompt = this.ui.getPromptAction();
    let content: ComponentContent<PromptData> | undefined;
    const data = new PromptData(event.message, event.value, (value?: string) => {
      if (value === undefined) event.result.handleCancel();
      else event.result.handlePromptConfirm(value);
      if (content) prompt.closeCustomDialog(content).then(() => content?.dispose());
    });
    content = new ComponentContent(this.ui, wrapBuilder(promptBuilder), data);
    prompt.openCustomDialog(content, { autoCancel: false }).catch(() => {
      event.result.handleCancel();
      content?.dispose();
    });
  }

  openWindow(event: OnWindowNewEvent): void {
    // Never leave the renderer waiting for a second Web controller.
    event.handler.setWebController(null);
    if (!/^https?:\/\//i.test(event.targetUrl)) return;
    const context = this.ui.getHostContext() as common.UIAbilityContext;
    context.openLink(event.targetUrl).catch((error: Error) => {
      console.error(`Unable to open external URL: ${error.message}`);
    });
  }
}
