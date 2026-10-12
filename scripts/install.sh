#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
service_name='Create tar.gz with Progress.workflow'
service_dir="$HOME/Library/Services"

if ! command -v pv >/dev/null 2>&1 && \
   [ ! -x /opt/homebrew/bin/pv ] && [ ! -x /usr/local/bin/pv ]; then
  echo 'pv is required. Install it with: brew install pv' >&2
  exit 1
fi

"$project_dir/scripts/build.sh"
/usr/bin/python3 "$project_dir/scripts/make_workflow.py"
mkdir -p "$service_dir"
/usr/bin/ditto "$project_dir/dist/$service_name" "$service_dir/$service_name"
/usr/bin/plutil -lint "$service_dir/$service_name/Contents/Info.plist"
/usr/bin/plutil -lint "$service_dir/$service_name/Contents/document.wflow"
/usr/bin/python3 "$project_dir/scripts/enable_quick_action.py"
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "Installed Finder Quick Action: $service_dir/$service_name"
echo 'If Finder does not show it immediately, relaunch Finder or log out and back in.'
