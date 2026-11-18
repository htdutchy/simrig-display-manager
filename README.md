# Simrig Display Manager

> A simple display manager script utilizing VideoInfo

Simrig Display Manager simplifies switching between a multi-monitor sim racing setup and a desktop display on the same PC. It provides an interactive menu for saving, restoring, and switching display configurations, accessible directly from the Windows Start menu.

Built around [VideoInfo by Terry MacDonald](https://github.com/terrymacdonald/VideoInfo), which does the actual saving and restoration of display settings. This repository contains only the launcher and PowerShell menu, **not VideoInfo itself**.

## Features

- Three resolution-independent display profiles:
  1. **Desk only**
  2. **Sim extended**, multiple independent sim displays
  3. **Sim Eyefinity** (AMD) or **Sim Surround** (NVIDIA), one grouped sim display
- Detects the graphics vendor automatically from VideoInfo's capture.
- Routes **Desk ↔ grouped sim** transitions through **Sim extended** for more reliable switching.
- Verifies transitions, allowing an intermediate setup time before applying the final profile.
- Save and overwrite confirmation dialogs, with backups of previous profiles.
- Diagnostics menu to compare the live and saved layouts.

**Compatibility:** Developed and verified on an AMD Eyefinity setup with VideoInfo 2.1.3. NVIDIA Surround detection and switching support are included but **not yet validated on real NVIDIA hardware**. Please report any issues.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1.
- An AMD Radeon or NVIDIA GPU with the appropriate graphics drivers/control panel installed.
- [VideoInfo](https://github.com/terrymacdonald/VideoInfo), download the Windows executable from [VideoInfo releases](https://github.com/terrymacdonald/VideoInfo/releases). Version 2.1.3 was used when developing this script.

Intel-only and mixed AMD/NVIDIA configurations aren't supported by this script yet, even though VideoInfo itself supports more configurations.

## Install

1. Download and extract this repository as a ZIP, or clone it.
2. Create a folder, for example `%USERPROFILE%\VideoInfo`.
3. Copy `VideoInfo-Menu.ps1` and `Run-VideoInfo.cmd` into that folder.
4. Extract `VideoInfo.exe` from the official VideoInfo release **into the same folder**.
5. Double-click `Run-VideoInfo.cmd` to open the menu.

## Creating the three profiles

Set up each layout manually in the Windows display settings and your GPU control panel. **The script saves and restores layouts, it does not create the initial Eyefinity/Surround group.**

1. Configure **Desk only**, only the desk monitor active. Run the menu, choose `9` (Save), then `1` and confirm.
2. Configure **Sim extended**, your sim monitors active as independent Windows screens. Choose `9` → `2` and confirm.
3. Configure **Sim grouped**, your sim monitors combined using Eyefinity or Surround. Choose `9` → `3` and confirm.

All monitors can remain physically connected. The script works with your saved arrangements and has no hard-coded resolution.

### AMD: Prefer Eyefinity Pro for a subset of monitors

For an AMD setup where **only the sim monitors should be grouped** and the desk monitor should be excluded, use **Eyefinity Pro** to create the Eyefinity group:

```text
C:\Program Files\AMD\CNext\CNext\EyefinityPro.exe
```

The file is normally included with the full AMD Adrenalin installation. If it is absent, check your installation and driver package.

VideoInfo's author recommends loading profiles created with Eyefinity Pro using `--oldEyefinity`. This script enables that switch **for AMD only** by default:

```powershell
$useOldEyefinity = $true
```

If your AMD profiles were created with Adrenalin's regular Eyefinity setup rather than Eyefinity Pro, you may need `$useOldEyefinity = $false` to use VideoInfo's default ADLX method. For details, see [VideoInfo's original README](https://github.com/terrymacdonald/VideoInfo#using-adl2-instead-of-adlx-for-amd-eyefinity-layouts).

### NVIDIA: Surround

Create a Surround group in the NVIDIA Control Panel, then save it using option `9` → `3`. On NVIDIA systems, the menu calls it **Sim Surround**, and the profile filename is `sim-surround.cfg`. The AMD-specific `--oldEyefinity` option is **not** passed to VideoInfo. The NVIDIA implementation is experimental until validated by NVIDIA users.

## Using the menu

```text
SIMRIG DISPLAY MANAGER

1. Desk only
2. Sim extended
3. Sim Eyefinity / Sim Surround

8. Display topology diagnostics
9. Save current display configuration
0. Exit
```

Choose `1`, `2`, or `3` to apply a saved profile. After applying the layout, the script checks whether the saved topology matches the live topology. Following a successful switch, it keeps the result visible for **5 seconds** before closing.

Choosing `9` opens a save submenu and confirmation dialog. Existing profile files are backed up in `backups\` before being overwritten. Option `8` is read-only and displays the compared layout signatures.

### Switching sequence

In order to prevent possible issues the script automatically sequences in and out of grouped display modes by first enabling extended mode.

```text
Desk only         -> Sim extended -> Sim Eyefinity / Surround
Sim grouped       -> Sim extended -> Desk only
Sim extended      -> Desk only / Sim grouped (direct)
```

For unknown current layouts, switching to Desk or a grouped layout also routes through Sim extended. If the intermediate layout does not verify correctly, the script stops instead of proceeding into the final layout.

Timing settings near the top of `VideoInfo-Menu.ps1`:

```powershell
$loadDelayMs = 500           # VideoInfo delay between operations
$transitionPauseMs = 3000   # Wait after the extended step
$verifyAttempts = 4
$verifyIntervalMs = 1000
$exitDelaySeconds = 5        # Show output for 5 seconds after success
```

## Pin to the Windows Start menu

1. Right-click `Run-VideoInfo.cmd` and select **Show more options → Create shortcut**, or create a desktop shortcut using **Send to → Desktop (create shortcut)**.
2. Press **Win + R** and enter `shell:programs`.
3. Copy the **shortcut**, not the actual `.cmd` or PowerShell files, into the Start Menu Programs folder that opens.
4. Open Start and search for **Simrig Display Manager** (rename the shortcut first if you want that label).
5. Right-click the result and choose **Pin to Start**.

You can then open the interactive menu from Start with one click. If Windows doesn't offer **Pin to Start** from search, open **All apps**, find the shortcut, and right-click it there.

## Troubleshooting

- **Shows Unknown:** Use option `8` to inspect topology differences. A profile can load successfully while some attributes differ; capture it again with `9` after the layout is stable.
- **Switch doesn't complete:** The script checks the intermediate topology and refuses to run the final load if verification fails. Increase `$transitionPauseMs` or `$verifyAttempts` if your monitors take longer to settle.
- **AMD Eyefinity behaves strangely:** If you built the group with Eyefinity Pro, keep `$useOldEyefinity = $true`. See the [upstream explanation](https://github.com/terrymacdonald/VideoInfo#using-adl2-instead-of-adlx-for-amd-eyefinity-layouts).
- **Multiple GPUs:** Not supported yet. The script intentionally refuses to guess which vendor to control.
- **Missing VideoInfo.exe:** Put it beside both scripts. The launcher automatically resolves its own directory.

**Privacy:** `.cfg` files can include monitor EDIDs, device paths, and GPU details. This repository intentionally ignores `.cfg` files, logs, backups, and `VideoInfo.exe`. Do not publish your personal profiles or diagnostic dumps without reviewing/redacting them.

## Credits and license

Script distributed under **GPL-3.0**.
VideoInfo is developed separately by **Terry MacDonald** and licensed under **GPL-3.0**. This repository does not bundle VideoInfo binaries or source code. Get it from the [official VideoInfo repository](https://github.com/terrymacdonald/VideoInfo).
