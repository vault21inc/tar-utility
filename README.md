# Tar Utility for Finder

Adds **Create tar.gz with Progress** to Finder's **Quick Actions** menu for folders. It creates a `.tar.gz` beside each selected folder and shows a separate macOS window with percentage, bytes processed, and estimated time remaining. Existing archives are preserved by adding `-2`, `-3`, and so on to the filename.

The app uses macOS `tar` and `gzip`, plus [`pv`](https://www.ivarch.com/programs/pv.shtml) to count bytes flowing through the archive pipeline. The progress window is built with AppKit; swiftDialog is not required. The percentage and ETA use a quick scan of the folder's logical file sizes, so they are estimates. The bar reaches 100% only after all commands finish successfully.

## Install

Requires macOS 15 or later, Xcode Command Line Tools, and `pv` (`brew install pv`).

```bash
cd /Users/thedaego/development/macos/tar-utility
./scripts/install.sh
```

In Finder, right-click one or more folders and choose **Quick Actions > Create tar.gz with Progress**. If it does not appear right after installation, relaunch Finder or log out and back in.

The installed Quick Action launches `dist/TarUtility.app` from this project. Keep this project at its current path while using the action. Re-run `./scripts/install.sh` after moving the project or changing its source.

## Changes made by installation

`./scripts/install.sh` makes these changes for the current macOS user:

| Location | Change |
| --- | --- |
| `build/module-cache/` in this project | Creates a Swift compiler module cache. |
| `dist/TarUtility.app` in this project | Builds or updates the app executable and copies its `Info.plist`. The app stays in the project; it is not copied to `/Applications`. |
| `dist/Create tar.gz with Progress.workflow` in this project | Generates the Automator Quick Action from the included template. It embeds the absolute path to this project's `dist/TarUtility.app`. An existing generated workflow at this path is replaced. |
| `~/Library/Services/Create tar.gz with Progress.workflow` | Creates `~/Library/Services` if needed, then copies or updates the Finder Quick Action. The workflow accepts folders selected in Finder and launches the app. |
| The current user's `pbs` preferences (normally `~/Library/Preferences/pbs.plist`) | Adds or updates only the `NSServicesStatus` entry named `(null) - Create tar.gz with Progress - runWorkflowAsService`. It sets `presentation_modes` for `ContextMenu`, `FinderPreview`, `ServicesMenu`, and `TouchBar` to `1`. This is the enabled **Create tar.gz with Progress** switch under **System Settings > General > Login Items & Extensions > Finder**. Other service entries are retained. |
| macOS Services cache | Requests a `pbs -flush` and `pbs -update` so Finder can discover the action. These refresh commands are best effort; Finder may still need to be relaunched or the user may need to log out and back in. |

The preference update briefly creates a plist in the system temporary directory and removes it before the installer exits. The installer checks for `pv` but does not install it; install that prerequisite separately with `brew install pv`. It does not use `sudo`, add a login item or background daemon, install a Finder extension binary, grant privacy permissions, or change the older **Create .tar** Quick Action.

When you **run** the Quick Action, the app creates a `.tar.gz` beside each selected folder. While working, it uses a hidden partial archive beside the folder and an error log in the system temporary directory; both are normally removed after success, failure, or cancellation. A force quit or system crash can leave them behind.

## Build and test

```bash
./scripts/build.sh
./dist/TarUtility.app/Contents/MacOS/TarUtility --headless "/path/to/a folder"
tar -tzf "/path/to/a folder.tar.gz"
```

The `--headless` mode runs the same archive engine without opening a window. It is useful for checking archive contents. A failed or cancelled operation removes its partial archive.

## Remove the Finder action

Move `~/Library/Services/Create tar.gz with Progress.workflow` to Trash. The app and project can then be removed separately. The `pbs` preference entry described above is not removed by moving the workflow; without the workflow, it has no action to launch.
