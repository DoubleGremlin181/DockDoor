<a id="readme-top"></a>

<div align="center">

<img src="Assets/Assets.xcassets/AppIcon.appiconset/AppIcon-iOS-Default-512x512@1x.png" alt="DockDoor Logo" width="128"/>

</div>

<h1 align="center">DockDoor</h1>

<div align="center">

<p>
  <a href="https://github.com/ejbills/DockDoor/releases/latest/download/DockDoor.dmg">
    <img src="https://img.shields.io/github/downloads/ejbills/DockDoor/latest/total?style=flat&label=Downloads%20%40latest&labelColor=444&logo=hack-the-box&logoColor=white&cacheSeconds=600" alt="Latest downloads">
  </a>
  <a href="https://github.com/ejbills/DockDoor/releases">
    <img src="https://img.shields.io/github/downloads/ejbills/DockDoor/total?label=Total%20Downloads" alt="Total downloads">
  </a>
</p>

![Swift](https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white)
![XCode](https://img.shields.io/badge/Xcode-007ACC?style=for-the-badge&logo=Xcode&logoColor=white)
![Git](https://img.shields.io/badge/GIT-E44C30?style=for-the-badge&logo=git&logoColor=white)
![MacOS](https://img.shields.io/badge/mac%20os-000000?style=for-the-badge&logo=apple&logoColor=white)

Effortless Alt+Tab switching and dock previews that respect your privacy.

</div>

> [!NOTE]
> **This is [DoubleGremlin181](https://github.com/DoubleGremlin181)'s fork of [DockDoor](https://github.com/ejbills/DockDoor).** It adds a [Space Switcher](#space-switcher) and [per-display desktop memory](#remember-desktop-layouts-per-display) on top of upstream, which it tracks. The sections from [About The Project](#about-the-project) down are upstream's README.

## This Fork

### Install

With Homebrew:

```sh
brew install --cask doublegremlin181/tap/dockdoor-fork
```

Or with the install script, which downloads the latest release, checks that it's signed by this fork, and installs and opens it:

```sh
curl -fsSL https://raw.githubusercontent.com/DoubleGremlin181/DockDoor/HEAD/install.sh | bash
```

Grant Accessibility and Screen Recording when DockDoor asks. After that it updates itself from this fork's releases.

The fork is signed with a free developer certificate but not notarized, since notarization needs Apple's paid Developer Program. Homebrew and the script clear macOS's quarantine flag on DockDoor, so it opens without a warning. If you'd rather install by hand, download [DockDoor.dmg](https://github.com/DoubleGremlin181/DockDoor/releases/latest/download/DockDoor.dmg) from the [latest release](https://github.com/DoubleGremlin181/DockDoor/releases/latest) and drag DockDoor into Applications. Its first launch then shows *Apple could not verify "DockDoor" is free of malware* with only **Move to Trash** and **Done**:

1. Click **Done**.
2. Open **System Settings › Privacy & Security** and scroll to **Security**, where *"DockDoor" was blocked* has an **Open Anyway** button. Click it and authenticate.
3. Open DockDoor again and click **Open Anyway** in the dialog.

The fork has its own bundle ID (`io.github.doublegremlin181.DockDoor`), so its settings and permissions are separate from upstream DockDoor and it never updates to an upstream build. Quit upstream DockDoor before using it, since both hook the Dock and the same shortcuts.

Versions look like `1.40.1-fork.3`: the upstream release the build is based on, then a count of fork releases on that base. Each release's notes link the exact upstream commit.

### Space Switcher

Press **Option+Tab** to see every Space on every display, each with a preview of its windows. Keep holding Option and tap Tab to move through them, then release to switch. The switch lands directly on the chosen Space, even several desktops away, without animating through the ones in between.

- **Preview styles:** Mini desktop (window thumbnails at their real positions), Exploded (spread out like Mission Control) or Window list (compact rows).
- **Move windows between Spaces:** press **M** to send the active window to the selected Space, or drag windows onto another Space while the switcher is open.
- **Multiple displays:** one row per display with Mission Control's desktop numbering and optional display names. Rows can be ordered main display first, left to right, top to bottom, or by the display with the mouse or active window. The switcher opens on the screen with the mouse, the one with the active window, or a pinned screen.
- **Stay open:** turn off **Release initializer key to switch Space** to keep the switcher open after releasing the shortcut. Navigate with the arrow keys and confirm with the selection key or a click.
- **Also:** start on the next Space, move the cursor to the selected display after switching, adjust card width and Space labels, and change the shortcut. Shortcuts that clash with the Window Switcher are detected.

It's off by default: turn it on in **Settings › Space Switcher**. Shortcuts live under **Settings › Gestures & Keybinds**.

### Remember desktop layouts per display

When a display is unplugged, macOS piles its windows onto the remaining display. With this on, DockDoor keeps the unplugged display's desktops apart and moves each window back to its original display and desktop when the display returns. Only windows the Space Switcher has seen are remembered, and desktops are never created or removed. It needs **Displays have separate Spaces** (System Settings › Desktop & Dock) and lives under **Settings › Space Switcher › Display memory**.

![Screenshot](/resources/dockdoorHero.png)

## Table of Contents

  <ol>
    <li><a href="#about-the-project">About The Project</a></li>
    <li><a href="#dockdoor-pro">DockDoor Pro</a></li>
    <li><a href="#features">Features</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
  </ol>

## About The Project

**DockDoor** reintroduces the missing "Window Peeking" functionality to macOS, inspired by the utility found in Windows and Linux environments.

While the native macOS Dock is iconic, it often lacks context when multiple windows of the same application are open. DockDoor solves this by allowing you to visualize, manage, and switch between your open windows simply by hovering over your Dock icons.

Built entirely open-source, DockDoor is designed to feel like a native extension of the operating system. Fast, lightweight, and seamlessly integrated!

For full details, features, and documentation, please visit **[dockdoor.net](https://dockdoor.net)** ⭐

<p align="right"><a href="#readme-top">Back to top ⬆️</a></p>

## DockDoor Pro

<a href="https://pro.dockdoor.net"><img src="/resources/pro/scene-previews.webp" alt="DockDoor Pro"/></a>

**DockDoor Free has no paywall and never will.** Every feature in this repo is free, forever.

**[DockDoor Pro](https://pro.dockdoor.net)** is a separate paid app from the same developer for people who want far more extensive control over their system. It replaces the macOS Dock entirely, and buying it is the best way to support DockDoor Free:

- Live window previews with 20+ actions, plus a full Alt+Tab replacement
- Spring magnification at your display's full refresh rate
- Folder fan-out, a drag-and-drop file tray with AirDrop, and right-click quick actions
- Liquid Glass, frosted or clear materials, profiles, and a different dock on every display
- Widget marketplace with clock, weather, battery, now playing, and community widgets

$20 one-time for 3 Macs. No subscription, 14-day money-back guarantee.

<p align="right"><a href="#readme-top">Back to top ⬆️</a></p>

## Features

### Dock Previews

![Dock Previews](/resources/dockdoorHero.png)

### Alt+Tab Switching

![Alt+Tab Switching](/resources/dockdoorSwitcherHero.png)

### Cmd+Tab Enhancements

![Cmd+Tab Enhancements](/resources/cmd-tab-enhancements.png)

### Dock Preview Layouts

![Dock Preview Layouts 1](/resources/variations/dockpreview1.png)
![Dock Preview Layouts 2](/resources/variations/dockpreview2.png)

### Window Switcher Layouts

![Window Switcher Layouts 1](/resources/variations/windowswitcher1.png)
![Window Switcher Layouts 2](/resources/variations/windowswitcher2.png)

### Dock Locking

![Dock Locking](/resources/dockLocking.png)

Lock the Dock to a specific monitor in multi-display setups so it stops jumping between screens.

### Calendar Integration

![Window Switcher Layouts](/resources/calendar.png)

### Compact List View

![Compact List View](/resources/listView.png)

### Enhanced Previews
![Enhanced Previews](/resources/largePreviewDemo.png)

### For more awesome features please visit **[dockdoor.net](https://dockdoor.net)** ⭐

<p align="right"><a href="#readme-top">Back to top ⬆️</a></p>

## Contributing

- ⭐ [Star on Github: Help others discover DockDoor](https://github.com/ejbills/DockDoor)

- 🐛 [Report Issues: Help us improve the app](https://github.com/ejbills/DockDoor/issues)

- 🌍 [Help Translate: Make DockDoor global](https://crowdin.com/project/dockdoor)

<p align="right"><a href="#readme-top">Back to top ⬆️</a></p>

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

<p align="right"><a href="#readme-top">Back to top ⬆️</a></p>
