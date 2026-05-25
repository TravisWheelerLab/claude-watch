#!/bin/sh
# Pull the latest source and reinstall (rebuild + relaunch the LaunchAgent).
# Invoked from the menu-bar "Update available" item, or run by hand.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Updating claude-watch in $DIR"
git -C "$DIR" pull --ff-only
sh "$DIR/install.sh"
