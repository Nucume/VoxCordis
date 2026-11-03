#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One VoxCordis at a time: a second launch brings the running window
  // forward (out of the tray or the taskbar too) and quits.
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Local\\com.nucume.voxcordis.single");
  bool running =
      single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
  // 0.3.7 and older (companion.exe) held another name; still running after
  // an update, it comes forward the same way.
  HANDLE older =
      ::OpenMutexW(SYNCHRONIZE, FALSE, L"Local\\com.nucume.companion.single");
  if (older != nullptr) {
    ::CloseHandle(older);
    running = true;
  }
  if (running) {
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"VoxCordis");
    if (existing != nullptr) {
      if (!::IsWindowVisible(existing)) ::ShowWindow(existing, SW_SHOW);
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    if (single_instance != nullptr) ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // The name Windows shows on notifications and groups the taskbar by.
  ::SetCurrentProcessExplicitAppUserModelID(L"com.nucume.voxcordis");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"VoxCordis", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
