#!/bin/bash
set -eo pipefail

sudo pacman -Syu --noconfirm

PYTHONUNBUFFERED=1 exec "$(dirname "$0")/build.py" "$@"
