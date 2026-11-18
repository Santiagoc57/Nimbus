#!/bin/zsh
# Puts each Nimbo account in Finder's Favorites under its own name
# («🏀 B A S Q U E T» instead of «Nimbo» or «Nimbo - …»).
#
# Truco: macOS 27 ignora el nombre que se pasa al añadir un favorito y muestra
# la carpeta de File Provider con el nombre de la app. Un favorito que apunta a
# un enlace simbólico muestra el nombre del enlace. Por eso se crea, por cuenta,
# ~/Library/Application Support/Nimbo/Sidebar/<nombre> -> ~/Library/CloudStorage/Nimbo-…
# y se pone ese enlace en Favoritos en lugar de la carpeta.
# Nimbo hace lo mismo al conectar cada cuenta (NimboFinderIcon.addToSidebar);
# este script sirve para aplicarlo a mano en un Mac con una versión anterior.
#
# Uso: zsh scripts/finder-sidebar-names.sh   (se puede repetir sin problema)
set -euo pipefail
ROOT=${0:A:h:h}
LINKS="$HOME/Library/Application Support/Nimbo/Sidebar"
HELPER=$(mktemp -d)/nimbo-sidebar
trap 'rm -rf "${HELPER:h}"' EXIT

cat > "${HELPER:h}/main.c" <<'C'
#include "Sidebar.h"
#include <string.h>
static CFURLRef url(const char *p) { return CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)p, strlen(p), true); }
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "remove")) { NimboRemoveFinderFavorites(url(argv[2])); return 0; }
    if (argc == 4 && !strcmp(argv[1], "set")) {
        CFStringRef name = CFStringCreateWithCString(NULL, argv[3], kCFStringEncodingUTF8);
        NimboSetFinderFavorite(url(argv[2]), name, NULL); return 0;
    }
    return 2;
}
C
xcrun clang -w -I "$ROOT/source" "${HELPER:h}/main.c" "$ROOT/source/Sidebar.c" \
  -framework CoreServices -framework CoreFoundation -o "$HELPER"

# Name chosen in Nimbo for a folder, or the folder name without «Nimbo-».
name_for() {
  /usr/bin/python3 - "$1" <<'PY'
import plistlib, subprocess, sys
folder = sys.argv[1]
raw = subprocess.run(["defaults", "export", "local.nimbo.cloudsearch", "-"], capture_output=True).stdout
prefs = plistlib.loads(raw) if raw else {}
value = prefs.get("NimboSidebarFavorite." + folder, "")
print(value.split("|")[0] if value else folder.rsplit("/", 1)[-1].removeprefix("Nimbo-"))
PY
}

mkdir -p "$LINKS"
for folder in "$HOME"/Library/CloudStorage/Nimbo-*(N/); do
  name=$(name_for "$folder")
  safe=${${name//\//-}//:/-}
  link="$LINKS/$safe"
  # Links with an older name for this account.
  for old in "$LINKS"/*(N@); do
    [[ $(readlink "$old") == "$folder" && "$old" != "$link" ]] && { "$HELPER" remove "$old"; rm -f "$old"; }
  done
  ln -sfn "$folder" "$link"
  "$HELPER" remove "$folder"
  "$HELPER" set "$link" "$name"
  echo "Favorito: $name"
done
