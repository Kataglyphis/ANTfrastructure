#!/usr/bin/env python3
"""test-uv-chain-ort.sh fixtures: wheel|pypi|site|reset build fake ORT wheels/dists; `uv` stands in for uv
(pip uninstall/install --python, sync from $STUB_SYNC_WHEELS; STUB_UV_KEEP / STUB_UV_FAIL_SYNC bend it)."""
import os
import shutil
import subprocess
import sys
import sysconfig
import zipfile

NATIVE_EXT = ".pyd" if os.name == "nt" else ".so"


def files(name, version, pkg, payload):
    info = f"{name.replace('-', '_')}-{version}.dist-info"
    body = {
        pkg + "/__init__.py": b"raise ImportError('built for another interpreter')\n" if payload == "broken" else b"",
        pkg + "/capi/state" + NATIVE_EXT: payload.encode(),
        info + "/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n".encode(),
        info + "/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: false\n",
    }
    body[info + "/RECORD"] = "".join(f"{p},,\n" for p in [*body, info + "/RECORD"]).encode()
    return body


def wheel(out, name, version, pkg, payload):
    v = f"{sys.version_info[0]}{sys.version_info[1]}"
    abi = "cp" + v + ("t" if sysconfig.get_config_var("Py_GIL_DISABLED") else "")
    plat = sysconfig.get_platform().replace("-", "_").replace(".", "_")
    path = os.path.join(out, f"{name.replace('-', '_')}-{version}-cp{v}-{abi}-{plat}.whl")
    with zipfile.ZipFile(path, "w") as z:
        for member, data in files(name, version, pkg, payload).items():
            z.writestr(member, data)


def pypi(site, name, version, pkg, payload):
    for member, data in files(name, version, pkg, payload).items():
        target = os.path.join(site, *member.split("/"))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as fh:
            fh.write(data)


def reset(*dirs):
    for d in dirs:
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)


def site_of(python):
    code = "import sysconfig; print(sysconfig.get_path('purelib'))"
    return subprocess.check_output([python, "-c", code], text=True).strip()


def dist_name(site, entry):
    with open(os.path.join(site, entry, "METADATA")) as fh:
        return next(line.split(":", 1)[1].strip() for line in fh if line.startswith("Name:"))


def uninstall(site, names):
    wanted = {n.replace("_", "-").lower() for n in names}
    for entry in sorted(os.listdir(site)):
        if not entry.endswith(".dist-info") or dist_name(site, entry).replace("_", "-").lower() not in wanted:
            continue
        with open(os.path.join(site, entry, "RECORD")) as fh:
            paths = [os.path.join(site, *line.split(",")[0].split("/")) for line in fh if line.strip()]
        for path in paths:
            if os.path.isfile(path):
                os.remove(path)
        shutil.rmtree(os.path.join(site, entry), ignore_errors=True)


def uv(argv):
    with open(os.environ["STUB_UV_LOG"], "a") as log:
        log.write("uv " + " ".join(argv) + "\n")
    if argv[:1] == ["sync"]:
        if os.environ.get("STUB_UV_FAIL_SYNC") == "1":
            return 1
        env = os.environ["UV_PROJECT_ENVIRONMENT"]
        python = next(p for p in (os.path.join(env, "bin", "python"), os.path.join(env, "Scripts", "python.exe"))
                      if os.path.exists(p))
        feed = os.environ["STUB_SYNC_WHEELS"]
        argv = ["pip", "install", "--python", python] + [os.path.join(feed, w) for w in sorted(os.listdir(feed))]
    if argv[:2] not in (["pip", "uninstall"], ["pip", "install"]):
        return 0
    python = argv[argv.index("--python") + 1]
    site = site_of(python)
    rest = [a for a in argv[2:] if not a.startswith("--") and a != python]
    if argv[1] == "uninstall" and os.environ.get("STUB_UV_KEEP") != "1":
        uninstall(site, rest)
    if argv[1] == "install":
        for whl in rest:
            with zipfile.ZipFile(whl) as z:
                z.extractall(site)
    return 0


def main(argv):
    cmd, args = argv[1], argv[2:]
    if cmd == "uv":
        return uv(args)
    if cmd == "site":
        print(sysconfig.get_path("purelib"))
    else:
        {"wheel": wheel, "pypi": pypi, "reset": reset}[cmd](*args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
