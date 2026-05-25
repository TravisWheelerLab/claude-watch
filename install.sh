#!/bin/sh
# Build ClaudeWatch.app, install it to ~/Applications, and register a
# LaunchAgent so it starts at login (and relaunches if it crashes).
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="ClaudeWatch.app"
LABEL="com.traviswheeler.claudewatch"
DEST="$HOME/Applications"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

# 1. Build
sh "$DIR/build.sh"

# 2. Install app bundle
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$DIR/build/$APP" "$DEST/$APP"
EXEC="$DEST/$APP/Contents/MacOS/claude-watch"

# Record this source checkout in the installed bundle so the app can self-update
# (git fetch/pull from here using the user's existing git auth).
PLIST_INFO="$DEST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CWSourcePath string $DIR" "$PLIST_INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CWSourcePath $DIR" "$PLIST_INFO"

# 3. Write LaunchAgent plist
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXEC</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# 4. (Re)load via launchd, then start immediately.
# bootout can lag behind; pause and retry bootstrap to avoid a race that
# surfaces as "Bootstrap failed: 5: Input/output error".
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
  || { sleep 2; launchctl bootstrap "gui/$UID_NUM" "$PLIST"; }
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "Installed $DEST/$APP and loaded LaunchAgent $LABEL"
