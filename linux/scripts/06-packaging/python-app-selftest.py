#!/usr/bin/env python3
"""Runs a Python app bundle's self-test command and proves its JSON report; see docs/python-app-bundles.md § What the builders do."""

import argparse
import json
import subprocess
import sys


def last_report(text: str) -> dict:
    """The last block from a bare '{' line to a bare '}' line: ONNX Runtime may print notices with braces first."""
    lines = text.splitlines()
    ends = [i for i, line in enumerate(lines) if line == "}"]
    starts = [i for i in range(ends[-1] + 1) if lines[i] == "{"] if ends else []
    if not starts:
        raise ValueError("the self-test printed no JSON report")
    return json.loads("\n".join(lines[starts[-1] : ends[-1] + 1]))


def plugin_refusal(report: dict, name: str, deviceless_error: str, root: str) -> str:
    """Why the report fails the plugin EP requirement, or '' when it registered or failed only for want of the device."""
    registered = report.get("registered_plugin_eps", [])
    if not name or name in registered:
        return ""
    error = str(report.get("plugin_ep_errors", {}).get(name, ""))
    # Only the bundle's own module reaching the device query counts; an image copy or a load failure does not.
    if deviceless_error and root and deviceless_error in error and root.rstrip("/") + "/" in error:
        sys.stderr.write(f"{name} did not register on this host without the device, as accepted: {error}\n")
        return ""
    return f"the self-test did not register the plugin EP {name}: {registered}" + (f"; its error: {error}" if error else "")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default="", help="the report's onnxruntime_module must lie under this directory")
    parser.add_argument("--require-available-provider", default="", help="require the named provider in the installed runtime")
    parser.add_argument("--require-provider", default="", help="require the named execution provider in the inference session")
    parser.add_argument("--require-registered-plugin", default="",
                        help="require the named plugin EP (e.g. MIGraphX) among the report's registered_plugin_eps")
    parser.add_argument("--deviceless-plugin-error", default="",
                        help="on a host without the GPU: accept this error of that plugin EP, naming a module under --root, instead")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="the launcher and its self-test arguments")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no self-test command")
    run = subprocess.run(command, stdout=subprocess.PIPE, text=True, check=False)
    sys.stderr.write(run.stdout)
    if run.returncode != 0:
        sys.exit(f"self-test '{' '.join(command)}' exited {run.returncode}")
    try:
        report = last_report(run.stdout)
    except ValueError as exc:
        sys.exit(str(exc))
    if not report.get("ok"):
        sys.exit("the self-test did not report ok")
    if args.require_available_provider and args.require_available_provider not in report.get("available_providers", []):
        sys.exit(f"the self-test did not list {args.require_available_provider} as available: {report.get('available_providers', [])}")
    refusal = plugin_refusal(report, args.require_registered_plugin, args.deviceless_plugin_error, args.root)
    if refusal:
        sys.exit(refusal)
    if args.require_provider and args.require_provider not in report.get("providers", []):
        sys.exit(f"the self-test did not activate {args.require_provider}: {report.get('providers', [])}")
    module = report.get("onnxruntime_module", "")
    if args.root and module and not module.startswith(args.root.rstrip("/") + "/"):
        sys.exit(f"the self-test loaded ONNX Runtime from {module}, outside {args.root}")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
