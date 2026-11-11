#!/usr/bin/env bash
# Flutter runner for WSL using Windows Flutter SDK via pushd drive mapping

WIN_PATH=$(wslpath -w "$PWD" | sed 's/wsl.localhost/wsl\$/')
CMD="pushd \"${WIN_PATH}\" && flutter.bat $* && popd"

(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c "$CMD")
