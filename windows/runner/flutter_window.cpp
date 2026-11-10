#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

// Taskbar thumbnail button ids (WM_COMMAND with THBN_CLICKED).
constexpr UINT kThumbPrev = 40101;
constexpr UINT kThumbPlay = 40102;
constexpr UINT kThumbNext = 40103;

UINT TaskbarCreatedMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"TaskbarButtonCreated");
  return message;
}

HICON LoadThumbIcon(int id) {
  return static_cast<HICON>(::LoadImageW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(id), IMAGE_ICON,
                                         ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON), 0));
}

THUMBBUTTON ThumbButton(UINT id, int icon, const wchar_t* tip) {
  THUMBBUTTON b = {};
  b.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
  b.iId = id;
  b.hIcon = LoadThumbIcon(icon);
  b.dwFlags = THBF_ENABLED;
  wcsncpy_s(b.szTip, tip, _TRUNCATE);
  return b;
}

}  // namespace

UINT FlutterWindow::ShowMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(L"OuOPlayerShowWindow");
  return message;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  instance_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ouoplayer/instance",
      &flutter::StandardMethodCodec::GetInstance());

  taskbar_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ouoplayer/taskbar",
      &flutter::StandardMethodCodec::GetInstance());
  taskbar_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "playing") {
          const auto* on = std::get_if<bool>(call.arguments());
          playing_ = on && *on;
          UpdatePlayButton(GetHandle());
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::AddThumbButtons(HWND hwnd) {
  if (!taskbar_list_) {
    if (FAILED(::CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_list_)))) return;
    if (FAILED(taskbar_list_->HrInit())) {
      taskbar_list_->Release();
      taskbar_list_ = nullptr;
      return;
    }
  }
  THUMBBUTTON buttons[] = {
      ThumbButton(kThumbPrev, IDI_THUMB_PREV, L"\u4e0a\u4e00\u9996"),
      ThumbButton(kThumbPlay, playing_ ? IDI_THUMB_PAUSE : IDI_THUMB_PLAY, playing_ ? L"\u66ab\u505c" : L"\u64ad\u653e"),
      ThumbButton(kThumbNext, IDI_THUMB_NEXT, L"\u4e0b\u4e00\u9996"),
  };
  // Explorer restarted: the buttons were added before, so only updated.
  thumb_buttons_added_ = thumb_buttons_added_
                             ? SUCCEEDED(taskbar_list_->ThumbBarUpdateButtons(hwnd, 3, buttons))
                             : SUCCEEDED(taskbar_list_->ThumbBarAddButtons(hwnd, 3, buttons));
}

void FlutterWindow::UpdatePlayButton(HWND hwnd) {
  if (!taskbar_list_ || !thumb_buttons_added_ || !hwnd) return;
  THUMBBUTTON b = ThumbButton(kThumbPlay, playing_ ? IDI_THUMB_PAUSE : IDI_THUMB_PLAY, playing_ ? L"\u66ab\u505c" : L"\u64ad\u653e");
  taskbar_list_->ThumbBarUpdateButtons(hwnd, 1, &b);
}

void FlutterWindow::OnDestroy() {
  taskbar_ = nullptr;
  if (taskbar_list_) {
    taskbar_list_->Release();
    taskbar_list_ = nullptr;
  }
  instance_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == ShowMessage()) {
    // Dart shows it, so the tray and the saved window state stay right.
    if (instance_) instance_->InvokeMethod("show", nullptr);
    return 0;
  }

  if (message == TaskbarCreatedMessage()) {
    AddThumbButtons(hwnd);
    return 0;
  }

  switch (message) {
    case WM_COMMAND:
      if (HIWORD(wparam) == THBN_CLICKED && taskbar_) {
        const UINT id = LOWORD(wparam);
        const char* name = id == kThumbPrev ? "prev" : id == kThumbNext ? "next" : id == kThumbPlay ? "toggle" : nullptr;
        if (name) {
          taskbar_->InvokeMethod("button", std::make_unique<flutter::EncodableValue>(std::string(name)));
          return 0;
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
