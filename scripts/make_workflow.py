#!/usr/bin/env python3
"""Create a Finder Quick Action that launches this project's app."""

import plistlib
import shlex
import shutil
import sys
from pathlib import Path


def main() -> None:
    project = Path(__file__).resolve().parent.parent
    app = (project / "dist" / "TarUtility.app").resolve()
    template = project / "templates" / "QuickAction.workflow"
    workflow = project / "dist" / "Create tar.gz with Progress.workflow"
    if not (app / "Contents" / "MacOS" / "TarUtility").is_file():
        raise SystemExit("Build the app before creating the workflow.")

    if workflow.exists():
        shutil.rmtree(workflow)
    shutil.copytree(template, workflow)

    document = workflow / "Contents" / "document.wflow"
    with document.open("rb") as stream:
        data = plistlib.load(stream)
    data["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"] = (
        f"/usr/bin/open -n -a {shlex.quote(str(app))} --args \"$@\""
    )
    with document.open("wb") as stream:
        plistlib.dump(data, stream, sort_keys=False)
    print(workflow)


if __name__ == "__main__":
    main()
