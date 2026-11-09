#!/usr/bin/env bash
# Flutter runner for WSL using Windows Flutter SDK via pushd drive mapping

WIN_WSL=$(wslpath -w "$PWD" | sed 's/wsl.localhost/wsl\$/')

/mnt/c/Windows/System32/cmd.exe /c "pushd \"${WIN_WSL}\" && flutter.bat $* && popd" < /dev/null
