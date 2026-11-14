<div align="center">

<img src="./docs/images/hero-banner.jpg" alt="Zeron Spider-Man Banner" width="100%" />

<br />

<img src="./icon.svg" alt="Spider-Man Icon" width="64" height="64" />

# 🕷️ Zeron Spider-Man

**Spider-Verse Atmosphere · Spider-Sense Session & Quota Radar · Smart Desktop Patrol Pet · Local Web Vault**

[![Zeron Plugin](https://img.shields.io/badge/Zeron-Plugin%20v1.1.0-e11d48?style=for-the-badge&logo=spider&logoColor=white)](https://github.com/yizixu/zeron-spider-man)
[![Luau](https://img.shields.io/badge/Built%20with-Luau-0ea5e9?style=for-the-badge&logo=lua&logoColor=white)](https://luau.org/)
[![i18n](https://img.shields.io/badge/i18n-EN%20%7C%20%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-10b981?style=for-the-badge)](#-languages)
[![License: MIT](https://img.shields.io/badge/License-MIT-f59e0b?style=for-the-badge)](./LICENSE)

**English** | [简体中文](./README.zh-CN.md)

</div>

---

> *"Anyone can wear the mask. Anyone can ship."*  
> Turn **Zeron** into your friendly neighborhood command center — complete with a live **NYC Spider-Verse skyline**, a **Spider-Sense radar** watching every background agent and API quota window, **smart text-aware roaming spiders** that never block your code, and an offline **SQLite Web Vault** for your sharpest prompts.

---

## ✨ What Makes It Special

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>🕸️ 1. Living Desktop Spider Companions</h3>
      <p>Animated multi-spider buddies patrol your workspace edges, spin translucent corner webs, rappel down on silk threads, and mirror live Zeron sessions.</p>
      <ul>
        <li>🧭 <b>Layout-Aware Corridor Patrol</b> — Dynamically detects sidebar &amp; reading columns, steering spiders to outer margins and edges.</li>
        <li>👻 <b>Auto Ghost Transparency</b> — Spiders, spun webs, and whisper bubbles fade smoothly when passing over text, and snap back to <code>100%</code> on hover.</li>
        <li>⚡ <b>Live Session Binding</b> — Dedicated spiders track active/attention-needed sessions; completed turns trigger a celebratory <code>THWIP!</code> swing-out.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <h3>📡 2. Spider-Sense Radar &amp; Quota Gauges</h3>
      <p>Never miss a stalled background agent or hit an unexpected rate-limit wall again.</p>
      <ul>
        <li>🚨 <b>Live Session Telemetry</b> — Monitors running, waiting-for-approval, and errored chats with one-click jump.</li>
        <li>🕸️ <b>Spider-Web Radial Gauges</b> — Custom canvas radial web meters for Session / Daily / Weekly quota windows with configurable warning thresholds.</li>
        <li>🔔 <b>Smart Desktop Alerts</b> — Optional OS notifications when sessions need input, finish, error, or quota dips below threshold.</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🌆 3. Spider-Verse 3D Parallax Skyline</h3>
      <p>Transform Zeron's New Chat canvas into a living New York nightscape layered with foreground spiderwebs.</p>
      <ul>
        <li>🖱️ <b>Configurable 3D Depth</b> — Choose <code>Off</code>, <code>Subtle</code>, <code>Normal</code>, or <code>Deep</code> cursor parallax.</li>
        <li>🎨 <b>Hand-Crafted WebP Artwork</b> — Skyline backdrop, dangling spiders, Spider-Crest watermark, and corner web filigree.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <h3>💾 4. Local SQLite Web Vault &amp; Quick Prompts</h3>
      <p>Catch great AI replies and reusable prompts directly into your personal Spider-Web.</p>
      <ul>
        <li>📌 <b>One-Click "Save to Web"</b> — Hover any message to archive snippets right into local SQLite.</li>
        <li>⚡ <b>Composer Quick-Launch Bar</b> — Insert favorite prompt templates directly into the message box with one click.</li>
        <li>🔌 <b>Open Extension Slots</b> — Exposes <code>stage</code>, <code>pet_actions</code>, and <code>hub_actions</code> for ecosystem add-on plugins.</li>
      </ul>
    </td>
  </tr>
</table>

---

## 📸 Visual Showcase

### 🕷️ Smart Margin-Patrol Spiders &amp; Glass Action Popover
> Spiders patrol outer corridors, weave corner silk, dangle in the sidebar footer, and fade gracefully whenever crossing text zones.

<p align="center">
  <img src="./docs/images/spider-pet-showcase.jpg" alt="Desktop Spider Pet Showcase" width="92%" />
</p>

### 📡 Spider Hub — Spider-Sense Radar, Web Quota Gauges &amp; Prompt Vault
> One unified page (`🕷️ Spider Hub`) combining active session cards, radial Spider-Web quota meters, recent signal history, and your searchable SQLite prompt library.

<p align="center">
  <img src="./docs/images/spider-hub-showcase.jpg" alt="Spider Hub Dashboard Showcase" width="92%" />
</p>

### 🎨 Included Original Artwork (`art/`)
| NYC Night Skyline | Spider Crest | Dangling Patrol Spider | Foreground Web Filigree |
| :---: | :---: | :---: | :---: |
| <img src="./art/skyline.webp" width="220" alt="NYC Skyline" /> | <img src="./art/spider-crest.webp" width="120" alt="Spider Crest" /> | <img src="./art/sidebar-hanging-spider.webp" width="120" alt="Hanging Spider" /> | <img src="./art/web-near.webp" width="220" alt="Foreground Web" /> |

---

## 🚀 Installation

### Option A: One-Click `.zeron-plugin` Install (Recommended)
1. Download `spider-man-1.1.0.zeron-plugin` from the [**Latest Release**](https://github.com/yizixu/zeron-spider-man/releases/latest).
2. In **Zeron**, go to **Settings → Plugins → Install from file** (or drag-and-drop / use `install_plugin`).
3. Enable **Spider-Man**, and optionally set the **Spider-Verse Skyline** wallpaper in plugin settings!

### Option B: Install from Source (Developer Mode)
Clone or copy this repository into Zeron's local plugins directory:

- **Windows**: `%LOCALAPPDATA%\Zeron\plugins\spider-man`
- **macOS**: `~/Library/Application Support/Zeron/plugins/spider-man`
- **Linux**: `~/.local/share/Zeron/plugins/spider-man`

```bash
git clone https://github.com/yizixu/zeron-spider-man.git spider-man
```

Zeron will automatically validate, sign, and hot-reload the plugin.

---

## ⚙️ Settings & Customization

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| 🖼️ **New-chat wallpaper** | Wallpaper | On | Toggle Spider-Verse NYC skyline on the new-chat screen |
| 🌀 **3D Parallax depth** | `off` / `subtle` / `normal` / `deep` | `normal` | Cursor-tracking depth for skyline and foreground webs |
| 💊 **Spider-Sense radar pill** | Switch | `true` | Live task & quota pill in the sidebar header |
| 🔔 **Spider-Sense notifications** | Switch | `true` | OS alerts for waiting, errored, finished chats, and low quota |
| 🚨 **Quota alert threshold** | `10%` / `15%` / `25%` / `35%` | `15%` | Triggers crimson Spider-Sense alert below threshold |
| ⚡ **Composer web & quick prompts** | Switch | `true` | Web filigree & quick-prompt bar below the composer |
| 📌 **Save message to Web button** | Switch | `true` | Hover button on chat messages to save to SQLite |
| 🕸️ **Sidebar spider elements** | Switch | `true` | Sidebar Spider-Net divider & dangling patrol spider |
| 🕷️ **Panel roaming spiders** | Switch | `true` | Animated multi-spider companions with layout-aware fading |

---

## 🧩 Architecture & Extension Slots

`zeron-spider-man` is built cleanly in modular **Luau** and stays **100% workflow-agnostic** — other plugins can hook into it without modifying core code:

```text
zeron-spider-man/
├── init.luau           # Plugin lifecycle, UI placements & layout probes
├── pet.luau            # Multi-spider physics, silk weaving, text-zone avoidance & stage_snapshot
├── hub.luau            # Spider Hub page (Radar tab + SQLite Web Snippets & Prompts tab)
├── radar.luau          # Session polling, usage quota aggregation & OS notification dispatcher
├── web_gauge.luau      # Custom ink.canvas radial spiderweb quota gauges & sparklines
├── db.luau             # Local SQLite persistence for prompts & snippets
├── art/                # Hand-crafted .webp skyline, webs & spider mascots
└── locales/            # Full English (en.json) & Simplified Chinese (zh-Hans.json) i18n
```

### 🔌 Public Extension Slots (for Third-Party Add-ons)
Companion plugins can inject UI into `spider-man` using `zeron.place`:

| Slot Selector | Purpose | Shared Props Received |
| :--- | :--- | :--- |
| `slot:spider-man.stage` | Render extra overlay actors/effects on the window stage | `spider_stage` (`w`, `h_up`, `zones`, `webs`, `pets`) |
| `slot:spider-man.pet_actions` | Add custom action buttons inside the spider popover menu | `slot` / active session context |
| `slot:spider-man.hub_actions` | Add toolbar actions inside Spider Hub | Hub page state |

---

## 🔐 Permissions Used

Every permission declared in [`zeron-plugin.json`](./zeron-plugin.json) serves a visible user feature:
- `ui.add` / `ui.change` — Sidebar badge, composer quick-bar, wallpaper, and transparent pet stage
- `pages.add` / `navigate` — **Spider Hub** page and jumping directly to sessions
- `sessions.read` / `messages.read` / `usage.read` — Live task & quota monitoring + saving replies
- `compose` / `notifications` — Inserting quick prompts & sending Spider-Sense alerts

---

## 🌐 Languages

- [🇺🇸 English (README.md)](./README.md)
- [🇨🇳 简体中文 (README.zh-CN.md)](./README.zh-CN.md)

---

<div align="center">

Made with 🕸️ for **Zeron** · MIT License © 2026 [yizixu](https://github.com/yizixu)

</div>
