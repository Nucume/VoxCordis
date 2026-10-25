// Loads the browser window plugin when WebKitGTK is installed. The plugin is
// not linked into the app (see linux/CMakeLists.txt), so this stands in for
// its register function: without WebKitGTK the plugin stays unregistered and
// the app starts anyway.
#include <dlfcn.h>
#include <limits.h>
#include <unistd.h>

#include <string>

#include <desktop_webview_window/desktop_webview_window_plugin.h>

void desktop_webview_window_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  char exe[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return;
  exe[n] = '\0';
  std::string path(exe);
  path = path.substr(0, path.rfind('/')) +
         "/lib/libdesktop_webview_window_plugin.so";

  void* plugin = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (plugin == nullptr) {
    g_message("Browser window unavailable: %s", dlerror());
    return;
  }
  using Register = void (*)(FlPluginRegistrar*);
  auto register_plugin = reinterpret_cast<Register>(
      dlsym(plugin, "desktop_webview_window_plugin_register_with_registrar"));
  if (register_plugin != nullptr) register_plugin(registrar);
}
