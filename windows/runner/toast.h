#ifndef RUNNER_TOAST_H_
#define RUNNER_TOAST_H_

#include <windows.h>

#include <string>

// Shows a Windows toast under the app identity |app_id|: |title| and |body|
// beside the picture at |image_path| (a local file, may be empty). When the
// toast is clicked while the app runs, |click_message| is posted to |window|.
// |icon_path| is the app's own icon for the name Windows shows. Returns false when Windows refuses it.
bool ShowToast(const std::wstring& app_id, const std::wstring& title,
               const std::wstring& body, const std::wstring& image_path,
               const std::wstring& icon_path, HWND window, UINT click_message);

#endif  // RUNNER_TOAST_H_
