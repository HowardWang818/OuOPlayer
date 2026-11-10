#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include <shobjidl.h>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // With |start_hidden| it stays hidden after the first frame.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden);
  virtual ~FlutterWindow();

  // Sent by a second start of OuOPlayer: show this window.
  static UINT ShowMessage();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // Leave the window hidden once the first frame is ready.
  bool start_hidden_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Tells the Dart side to show the window (`ouoplayer/instance`).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> instance_;

  // Previous / play-pause / next under the taskbar thumbnail
  // (`ouoplayer/taskbar`: "button" out, "playing" in).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> taskbar_;
  ITaskbarList3* taskbar_list_ = nullptr;
  bool thumb_buttons_added_ = false;
  bool playing_ = false;
  void AddThumbButtons(HWND hwnd);
  void UpdatePlayButton(HWND hwnd);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
