# Assets

The mockups of the app, each as an HTML source and the PNG rendered from it, and screenshots of the real app. They are what [SPEC.md](../SPEC.md#mockups) and the [README](../README.md) show.

## Files

- `mock.css`: the shared styles for all three mockups (colours, window chrome, status dots).
- `mock-main-window.html`, `mock-main-window.png`: the main window, connected over the tailnet.
- `mock-browser-chooser.html`, `mock-browser-chooser.png`: the chooser that opens from **Open stick page…**.
- `mock-settings.html`, `mock-settings.png`: the settings window.
- `app-main-window.png`: a screenshot of the installed app, connected over the tailnet; also the README's hero image.
- `app-settings.png`: the Settings window of the installed app, taken with `--show-settings`.
- `app-tailscale-missing.png`: a screenshot of the real app started with `--simulate tailscale-missing`.
- `app-viewer.png`: the built-in viewer with the stick's page, taken with `--open-viewer` and scaled to 1600 pixels wide.
- `app-viewer-waiting.png`: the viewer waiting for the tunnel, taken with `--simulate tailscale-missing --open-viewer`, same scale.
- `app-chooser.png`: the main window with the chooser open, taken with `--show-chooser`; the popover is its own window, the one without a name.

## After editing a mockup

> [!IMPORTANT]
> The PNG does not update itself. After changing an HTML file or `mock.css`, render the PNGs again and commit sources and images together.

Run from this folder. Each render is stopped after 7 seconds, because headless Chrome writes the screenshot but does not always exit on its own. The second number is the window height in points; raise it if the bottom of a window is cut off.

```bash
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for spec in "mock-main-window 520" "mock-browser-chooser 400" "mock-settings 440"; do
  set -- ${=spec}
  "$C" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --user-data-dir=/tmp/lsv-mock-render --window-size=716,$2 \
    --screenshot="$PWD/$1.png" "file://$PWD/$1.html" >/dev/null 2>&1 &
  sleep 7; pkill -f "user-data-dir=/tmp/lsv-mock-render"
done
rm -rf /tmp/lsv-mock-render
```

> [!NOTE]
> The loop is written for zsh (`${=spec}` splits the pair). In bash, write `set -- $spec` instead.

## Retaking a screenshot of the app

The `app-*.png` files are captures of the running window, not renders. Retake them when the window changes. From the repo root, after `swift build`, this starts the app, finds its window and captures only that window, then quits the app. Add `--simulate tailscale-missing` after the binary for the second screenshot. For the viewer, add `--open-viewer`, look the window up by its name `Stick page` instead of taking the first one, and scale the result with `sips -Z 1600`.

```bash
.build/debug/LTEStickView >/dev/null 2>&1 &
APP=$!
sleep 8
WID=$(swift -e "import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]; for w in l where (w[kCGWindowOwnerPID as String] as? Int32) == $APP && (w[kCGWindowLayer as String] as? Int) == 0 { print(w[kCGWindowNumber as String]!); break }")
screencapture -x -o -l $WID assets/app-main-window.png
kill -TERM $APP
```

> [!NOTE]
> `screencapture` needs Screen Recording permission for the terminal it runs in, granted once in System Settings, Privacy and Security.
