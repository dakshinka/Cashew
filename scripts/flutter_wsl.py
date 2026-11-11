#!/usr/bin/env python3
import sys, os, subprocess

path = os.getcwd()
win_path = subprocess.check_output(["wslpath", "-w", path]).decode().strip().replace("wsl.localhost", "wsl$")
args_str = " ".join(f'"{a}"' if (" " in a or "$" in a) else a for a in sys.argv[1:])
cmd = f"pushd {win_path} && flutter.bat {args_str} && popd"

stdin_mode = None if sys.stdin.isatty() else subprocess.DEVNULL
proc = subprocess.run(["/mnt/c/Windows/System32/cmd.exe", "/c", cmd], cwd="/mnt/c", stdin=stdin_mode)
sys.exit(proc.returncode)
