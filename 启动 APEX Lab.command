#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -x "dist/APEX Lab.app/Contents/MacOS/APEXLab" ]]; then
  ./build.sh
fi
open "$PWD/dist/APEX Lab.app"
