#!/usr/bin/env python3
"""Prepare OneXray iOS project and libXray core for an unsigned build.

Replicates app.flutter.build() for iOS, stopping before the signed
fastlane step (AppleBuilder.build_app); the caller then runs
`flutter build ipa --no-codesign` and packs the archive manually.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.apple import AppleBuilder
from app.command_line import run_command


def main() -> None:
    builder = AppleBuilder(
        "OneXray",
        "ios",
        os.path.dirname(os.path.abspath(__file__)),
    )
    marketing_version = builder.read_version().split("+", maxsplit=1)[0]
    builder.write_version(f"{marketing_version}+{builder.build_number}")
    run_command(["flutter", "pub", "get"], cwd=builder.root_dir)
    builder.before_build()
    run_command(["dart", "run", "tool/ffigen.dart"], cwd=builder.root_dir)


if __name__ == "__main__":
    main()
