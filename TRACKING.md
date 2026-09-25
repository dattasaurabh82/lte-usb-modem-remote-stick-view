# Tracking

> [!NOTE]
> **Status**: all seven build steps done; version 1.0.0 installed from `scripts/build-app.sh`
>
> **Verified**: `2026-09-25`, from the office over Tailscale, on the installed app; what each step checked is in its section of [SPEC.md](SPEC.md)
>
> **Open**: the checks under [Still to check](#still-to-check), most of them at home or by hand
>
> **Next**: run the home checks, then tick them here and move what they show into SPEC

---

<br><br>

Where the project stands: what was built, what is still to be checked, and what is known not to be handled. The design itself is in [SPEC.md](SPEC.md); the overview is the [README](README.md).

## Contents

- [Tracking](#tracking)
  - [Contents](#contents)
  - [Roadmap](#roadmap)
  - [Still to check](#still-to-check)
  - [Known gaps](#known-gaps)

---

## Roadmap

> [!IMPORTANT]
> All steps were built and pushed on `2026-09-25`, each ending with its tests and a SPEC update.

- [x] **Step 1**: repo, spec, mockups agreed and rendered
- [x] **Step 2**: tunnel core: ssh started and stopped, readiness through the modem, failure reasons, leftover cleanup
- [x] **Step 3**: Auto route choice, the Tailscale path, reconnect with backoff, network changes, the tailscale line with its fixes
- [x] **Step 4**: the built-in viewer, waiting for the tunnel and reloading after a drop
- [x] **Step 5**: external browsers with a proxy rule for the modem's address only; Chrome, Firefox and Edge tested; Arc listed as unusable
- [x] **Step 6**: Settings, Keychain passwords, the askpass helper, Detect from box
- [x] **Step 7**: build script, icon, Info.plist, installed as `LTE Stick View.app`, README

---

## Still to check

Each of these needs a place or a hand the build could not have from the office. When one is done, tick it here and write what was seen into the SPEC section named.

- [ ] **The home network path**: at home, Auto should pick the LAN target (*Home LAN* by default) and the built-in viewer should load over it. See [Choosing the route](SPEC.md#choosing-the-route).
- [ ] **A real password login**: a target in password mode against an sshd that accepts passwords, with the password saved in Settings. From the office our board is reachable only through Tailscale SSH, which never asks for one. See [Signing in](SPEC.md#signing-in).
- [ ] **A real network change**: Wi-Fi off and on with the window open, or arriving home with it open; the log should say *network changed*, and the tunnel should survive or come back. See [When the link drops](SPEC.md#when-the-link-drops).
- [ ] **The Settings buttons by hand**: Apply, Revert, Save, Forget, the arrows, Add target, and Detect from box clicked rather than run by `--detect`. See [Settings](SPEC.md#settings).
- [ ] **A Mac without Tailscale**, and one where the Tailscale app is installed but was never opened; only simulated so far. See [Without Tailscale](SPEC.md#without-tailscale).
- [ ] **A relayed Tailscale path**: the route line should turn yellow *relayed via* a region. See [What Tailscale adds](SPEC.md#what-tailscale-adds).
- [ ] **The two fix buttons clicked**: *Get Tailscale* and *Open Tailscale*; only their presence was checked.
- [ ] **Closing the main window by its close button** while a viewer window is open; only a quit event and `SIGTERM` were tested. See [Lifecycle](SPEC.md#lifecycle).
- [ ] **The untested browsers**: Brave, Vivaldi, Chromium, Firefox Developer Edition and Nightly, listed yellow *untested*. See [External browsers](SPEC.md#external-browsers).

---

## Known gaps

Not handled on purpose, or not yet; each is described where it applies.

- **Tailscale SSH check mode**: the sign-in URL shows in the log, but the 10 second wait for the SOCKS port ends the attempt first. See [Signing in](SPEC.md#signing-in).
- **Arc**: ignores the launch options that carry the proxy rule, so it cannot be used. See [External browsers](SPEC.md#external-browsers).
- **Safari**: follows only the system-wide proxy, which the app does not change.
- **Other Macs**: the app is signed ad hoc on the Mac that builds it and is not notarized; build it on each Mac. See [Build and install](SPEC.md#build-and-install).
- **The icon** is a placeholder drawn by `scripts/make-icon.swift`; a designed icon would replace `Resources/AppIcon.png`.
