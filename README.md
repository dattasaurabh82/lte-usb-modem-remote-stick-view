<div align="center">

# lte-usb-modem-remote-stick-view

**LTE Stick View: a small Mac app that opens the web page of the LTE stick on the Orange Pi Zero, through an SSH SOCKS tunnel via the box, from one window.**

![Platform: macOS 14 and later](https://img.shields.io/badge/platform-macOS%2014%2B-1e40af)
![Language: Swift and SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-1e40af)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-1e40af)
![Status: spec, no code yet](https://img.shields.io/badge/status-spec%2C%20no%20code%20yet-4a4946)

<img src="assets/mock-main-window.png" alt="LTE Stick View main window mockup: route switch, four status lines, Open stick page and Quit" width="720">

</div>

The Huawei stick that gives the Orange Pi Zero its mobile connection has its own web page at `192.168.8.1`, and only the box can reach it. From the Mac that takes an `ssh -D` tunnel in one terminal and a specially started browser in another, with the right host name for wherever we are. This app does the same thing from `/Applications`: it picks the route, holds the tunnel, proves the stick answers, and opens the page in the viewer you choose.

> [!NOTE]
> The mockup above is the agreed design, not a screenshot. The app is being built step by step; where it stands is in [LOG.md](LOG.md).

---

## Contents

- [lte-usb-modem-remote-stick-view](#lte-usb-modem-remote-stick-view)
  - [Contents](#contents)
  - [At a glance](#at-a-glance)
  - [Where to start](#where-to-start)
  - [Repository layout](#repository-layout)
  - [Roadmap](#roadmap)
  - [Related](#related)

---

## At a glance

- **What it does**: SSH SOCKS tunnel to the Orange Pi Zero, then the stick's page through it, in a built-in viewer or a browser picked each time.
- **Routes**: home LAN (`root@orangepizero.lan`) or the tailnet (`root@orangepizero`), chosen automatically by which one answers.
- **Sign-in**: Tailscale SSH on the tailnet, the Mac's key on the LAN, a Keychain password for any target that asks.
- **Browsers**: the built-in WebKit viewer, the Chromium family with their own profile, Firefox with a temporary profile; Safari is listed but not usable.
- **Leaves nothing behind**: no system proxy changes; quitting ends the tunnel.
- **Built with**: Swift and SwiftUI, no third-party dependencies.

---

## Where to start

- **To understand the design**: [SPEC.md](SPEC.md), with the chain diagram, every ssh flag explained, and the status words.
- **To resume work**: [LOG.md](LOG.md), the *Pick up here* section first, then [CONTEXT.md](CONTEXT.md) for the facts.
- **To change a mockup**: [assets/README.md](assets/README.md).
- **For the manual commands this app replaces**: the server repo's [runbook 05, Read the stick](https://github.com/dattasaurabh82/orangepizero-solar-server/blob/main/runbooks/05-network-setup.md#read-the-stick).

---

## Repository layout

```text
lte-usb-modem-remote-stick-view/
├── README.md        this page
├── SPEC.md          the design: tunnel, sign-in, routes, viewers, status lines
├── CONTEXT.md       facts about the box, the stick and the Mac, decisions, terms
├── LOG.md           step by step record and the resume point
├── .gitignore
└── assets/          mockups (HTML sources and rendered PNGs), index in its README
```

---

## Roadmap

- [x] Step 1: repo, spec, context, log, mockups
- [ ] Step 2: tunnel core
- [ ] Step 3: Auto route choice and reconnect
- [ ] Step 4: built-in viewer
- [ ] Step 5: external browsers
- [ ] Step 6: settings, Keychain, askpass
- [ ] Step 7: build script, icon, this README filled in

---

## Related

- [orangepizero-solar-server](https://github.com/dattasaurabh82/orangepizero-solar-server): the box this app reaches, and the stick's setup in [runbook 05](https://github.com/dattasaurabh82/orangepizero-solar-server/blob/main/runbooks/05-network-setup.md#read-the-stick).
