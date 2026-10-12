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

## Build and test

```bash
./scripts/build.sh
./dist/TarUtility.app/Contents/MacOS/TarUtility --headless "/path/to/a folder"
tar -tzf "/path/to/a folder.tar.gz"
```

The `--headless` mode runs the same archive engine without opening a window. It is useful for checking archive contents. A failed or cancelled operation removes its partial archive.

## Remove the Finder action

Move `~/Library/Services/Create tar.gz with Progress.workflow` to Trash. The app and project can then be removed separately.
