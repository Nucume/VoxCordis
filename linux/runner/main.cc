#include <stdlib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // WebKitGTK's DMA-BUF renderer can break the Wayland connection the
  // whole app shares (GTK then quits with "Error 71 (Protocol error)"),
  // notably on NVIDIA. The Soulkyn browser window doesn't need it. Set
  // before any thread starts; a value the user set wins.
  setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
