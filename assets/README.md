# Assets

The mockups of the app, each as an HTML source and the PNG rendered from it. The PNGs are what [SPEC.md](../SPEC.md#mockups) and the [README](../README.md) show.

## Files

- `mock.css`: the shared styles for all three mockups (colours, window chrome, status dots).
- `mock-main-window.html`, `mock-main-window.png`: the main window, connected over the tailnet.
- `mock-browser-chooser.html`, `mock-browser-chooser.png`: the chooser that opens from **Open stick page…**.
- `mock-settings.html`, `mock-settings.png`: the settings window.

## After editing a mockup

> [!IMPORTANT]
> The PNG does not update itself. After changing an HTML file or `mock.css`, render the PNGs again and commit sources and images together.

Run from this folder. Each render is stopped after 7 seconds, because headless Chrome writes the screenshot but does not always exit on its own. The second number is the window height in points; raise it if the bottom of a window is cut off.

```bash
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for spec in "mock-main-window 490" "mock-browser-chooser 360" "mock-settings 408"; do
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
