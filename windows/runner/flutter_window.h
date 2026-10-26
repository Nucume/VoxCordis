#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The tray icon, shown and hidden from Dart over "voxcordis/tray".
  bool ShowTray();
  void HideTray();
  void ShowTrayMenu();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;
  NOTIFYICONDATA tray_icon_{};
  bool tray_shown_ = false;

  // VoxCordis' own title bar draws its maximise button in Flutter. Windows 11
  // only offers Snap Layouts over a real one, so the spot of that button
  // (from Dart over "voxcordis/window", in the Flutter view's physical
  // pixels) is reported to Windows as the maximise button.
  static LRESULT CALLBACK ViewSubclassProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam,
                                           UINT_PTR id, DWORD_PTR data);
  bool OverMaxButton(LPARAM screen_point) const;
  void SetMaxButtonState(bool hover, bool down);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  HWND view_hwnd_ = nullptr;
  RECT max_button_{};
  bool max_hover_ = false;
  bool max_down_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
