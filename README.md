<div align="center">

# lte-usb-modem-remote-stick-view

**LTE Stick View: a small Mac app that opens the configuration page of a USB LTE modem plugged into a remote, headless Linux board (an Orange Pi Zero in our case, but any SBC or server you can SSH into), by tunnelling through that board, from one window.**

![Platform: macOS 14 and later](https://img.shields.io/badge/platform-macOS%2014%2B-1e40af)
![Language: Swift and SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-1e40af)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-1e40af)
![Status: step 2 of 7, tunnel core](https://img.shields.io/badge/status-step%202%20of%207%2C%20tunnel%20core-4a4946)
![License: LGPL-2.1](https://img.shields.io/badge/license-LGPL--2.1-4a4946)

<img src="assets/mock-main-window.png" alt="LTE Stick View main window mockup: route switch, four status lines, Open stick page and Quit" width="720">

</div>

Many USB LTE modems run in a router mode (Huawei calls it HiLink) and serve their own configuration page on a small private network that only the computer they are plugged into can see. When that computer is a board with no screen, somewhere else, reaching the page from a laptop takes an SSH tunnel and a specially started browser. This app does that from `/Applications`: it picks the route to the board, holds the tunnel, proves the modem answers, and opens the page in the viewer you choose.

> [!NOTE]
> The mockup above is the agreed design, not a screenshot. The app is being built step by step; where it stands is in the [roadmap](#roadmap) below, and [SPEC.md](SPEC.md) is kept up to date as it is built.

---

## Contents

- [lte-usb-modem-remote-stick-view](#lte-usb-modem-remote-stick-view)
  - [Contents](#contents)
  - [At a glance](#at-a-glance)
  - [Why this exists](#why-this-exists)
    - [The chore, in our case](#the-chore-in-our-case)
    - [What the app does instead](#what-the-app-does-instead)
  - [Where to start](#where-to-start)
  - [Repository layout](#repository-layout)
  - [Roadmap](#roadmap)
  - [Related](#related)
  - [License](#license)

---

## At a glance

- **What it does**: SSH SOCKS tunnel to the Orange Pi Zero, then the stick's page through it, in a built-in viewer or a browser picked each time.
- **Routes**: home LAN (`root@orangepizero.lan`) or the tailnet (`root@orangepizero`), chosen automatically by which one answers.
- **Sign-in**: Tailscale SSH on the tailnet, the Mac's key on the LAN, a Keychain password for any target that asks.
- **Browsers**: the built-in WebKit viewer, the Chromium family with their own profile, Firefox with a temporary profile; Safari is listed but not usable.
- **Leaves nothing behind**: no system proxy changes; quitting ends the tunnel.
- **Built with**: Swift and SwiftUI, no third-party dependencies.

---

## Why this exists

A USB LTE modem in router mode shows up on the board as a network card with its own little subnet, and the modem sits at the gateway address of that subnet with a web page for the SIM, the signal, the APN and the data counters. Only the board can reach that address. Your laptop cannot, even when it can SSH into the board.

The obvious fix, an SSH **port forward**, often gives a blank page. Many of these modems check the `Host` header of every request, and a forwarded request arrives as `localhost:8081` instead of the modem's own address, so the modem redirects the browser to an address the laptop has no route to.

What works is a **SOCKS proxy** through the board: `ssh -D` opens a local port, the browser sends every request through it, and the board opens each connection on the browser's behalf. The browser asks for the modem by its real address, the `Host` header is right, and the page loads.

### The chore, in our case

> [!IMPORTANT]
> Our board is an Orange Pi Zero, `orangepizero.lan` at home and `orangepizero` over Tailscale anywhere else. The modem is a Huawei E3372h-320 in HiLink mode at `192.168.8.1`. The outputs below were captured on `2026-09-25` over Tailscale. The server side is written up in [runbook 05, Read the stick](https://github.com/dattasaurabh82/orangepizero-solar-server/blob/main/runbooks/05-network-setup.md#read-the-stick).

**What does not work: a plain port forward.**

```bash
ssh -N -L 8081:192.168.8.1:80 root@orangepizero
curl -s -D - -o /dev/null http://localhost:8081/
```

The modem answers with a redirect and no body:

```text
HTTP/1.1 307
LOCATION: http://192.168.8.1/html/index.html?origin=xxx
Content-Type: text/plain
Content-Length: 0
```

**What works, by hand, every time:**

1. Open a first terminal and start the SOCKS proxy, picking the host name by where you are, and leave the session open:

```bash
ssh -D 1080 root@orangepizero.lan    # at home, on the LAN
ssh -D 1080 root@orangepizero        # anywhere else, over Tailscale
```

2. Open a second terminal and start a browser that uses only that proxy, with a profile of its own so the everyday browser is untouched:

```bash
open -na "Google Chrome" --args --proxy-server="socks5://127.0.0.1:1080" --user-data-dir=/tmp/stick-browser http://192.168.8.1/
```

3. Or check from the command line through the same proxy:

```bash
curl -s -D - -o /dev/null --socks5-hostname 127.0.0.1:1080 http://192.168.8.1/
```

```text
HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: 3106
```

4. When done, close the browser and end the SSH session.

That is two terminals, a host name to remember, a long browser command to find again, and a session that is easy to leave running.

*The app exists so that none of this has to be remembered.*

### What the app does instead

- **Picks the route**: tries the LAN name and the Tailscale name and uses whichever answers.
- **Holds the tunnel**: the same `ssh -D`, started and stopped with the window, with the exact command visible in the log.
- **Proves the chain**: shows green only once the modem itself has answered through the tunnel.
- **Opens the page**: in a built-in viewer or a browser picked each time, started with the proxy and its own profile.

For another board or modem, change the targets and the modem's address in Settings; our box is only the default.

**Everything else is in [SPEC.md](SPEC.md).**

---

## Where to start

- **To understand the design**: [SPEC.md](SPEC.md), with the chain diagram, every ssh flag explained, and the status words.
- **To see where it stands**: the [roadmap](#roadmap) below, and the note box at the top of [SPEC.md](SPEC.md).
- **To build and try it**: [Building and checking from the command line](SPEC.md#building-and-checking-from-the-command-line) in SPEC, including the headless `--self-test`.
- **To change a mockup**: [assets/README.md](assets/README.md).
- **For the manual commands this app replaces**: the server repo's [runbook 05, Read the stick](https://github.com/dattasaurabh82/orangepizero-solar-server/blob/main/runbooks/05-network-setup.md#read-the-stick).

---

## Repository layout

```text
lte-usb-modem-remote-stick-view/
├── README.md        this page
├── SPEC.md          the design: tunnel, sign-in, routes, viewers, status lines
├── LICENSE          GNU LGPL 2.1
├── Package.swift    the Swift package: one app target, macOS 14 and later
├── .gitignore
├── Sources/
│   └── LTEStickView/
│       ├── App.swift          app entry, quit handling, the --self-test mode
│       ├── ContentView.swift  the main window: route switch, four lines, log
│       ├── Tunnel.swift       the ssh process, readiness, failure reasons, leftover cleanup
│       ├── System.swift       port checks, lsof and ps lookups, the stick probe
│       └── Model.swift        targets, settings, status lines
└── assets/          mockups (HTML sources and rendered PNGs), index in its README
```

---

## Roadmap

- [x] Step 1: repo, spec, context, log, mockups
- [x] Step 2: tunnel core
- [ ] Step 3: Auto route choice and reconnect
- [ ] Step 4: built-in viewer
- [ ] Step 5: external browsers
- [ ] Step 6: settings, Keychain, askpass
- [ ] Step 7: build script, icon, this README filled in

---

## Related

- [orangepizero-solar-server](https://github.com/dattasaurabh82/orangepizero-solar-server): the box this app reaches, and the stick's setup in [runbook 05](https://github.com/dattasaurabh82/orangepizero-solar-server/blob/main/runbooks/05-network-setup.md#read-the-stick).

---

## License

LTE Stick View is released under the GNU Lesser General Public License, version 2.1. The full text is in [LICENSE](LICENSE).
