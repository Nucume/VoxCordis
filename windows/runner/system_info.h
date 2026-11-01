#ifndef RUNNER_SYSTEM_INFO_H_
#define RUNNER_SYSTEM_INFO_H_

#include <string>
#include <utility>
#include <vector>

// Straight from Windows' own APIs, so VoxCordis needs no other program to ask.

// Display adapters and their video memory in bytes (0 when not recorded).
std::vector<std::pair<std::wstring, unsigned long long>> DisplayAdapters();

// A known folder ("desktop", "documents", "downloads", "music", "pictures",
// "videos"), OneDrive-redirected if it is; empty when unknown.
std::wstring KnownFolderPath(const std::wstring& name);

// Adds (|command| non-empty) or removes the "VoxCordis" login item.
bool SetLoginItem(const std::wstring& command);

// A DWORD under HKEY_CURRENT_USER; false when it isn't there.
bool ReadUserDword(const std::wstring& key, const std::wstring& name,
                   unsigned long* value);

// The file name of the program running as process |pid| (e.g.
// "llama-server.exe"); empty when there is no such process.
std::wstring ProcessImageName(unsigned long pid);

// Opens a file, folder, shortcut or address the way double-clicking would.
bool OpenWithShell(const std::wstring& target);

#endif  // RUNNER_SYSTEM_INFO_H_
