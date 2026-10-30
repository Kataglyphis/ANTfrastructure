#!/usr/bin/env python3
"""Mutation tests for the actual ELF and linker cache dependency evidence."""
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

SUBJECT = Path(__file__).resolve().parents[1] / "06-packaging/python-app-deb-depends.py"
spec = importlib.util.spec_from_file_location("deb_depends", SUBJECT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DebianDependencies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="deb-depends-")
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.app = self.bundle / "app"
        source = self.root / "app.c"
        source.write_text('#include <stdio.h>\nint main(void) { puts("test"); return 0; }\n')
        subprocess.run(["cc", str(source), "-o", str(self.app)], check=True)
        (self.bundle / "bundle.json").write_text(json.dumps({"glibc": False}))
        self.fake = self.root / "fake"
        self.fake.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_subject(self):
        env = dict(os.environ, PATH=str(self.fake) + os.pathsep + os.environ["PATH"])
        return subprocess.run(["python3", str(SUBJECT), str(self.bundle)], env=env, text=True, capture_output=True, check=False)

    def fake_tool(self, name, script):
        path = self.fake / name
        path.write_text("#!/bin/sh\n" + script + "\n")
        path.chmod(0o755)

    def make_gpu_wrapper(self, directory):
        runtime_app = self.bundle / "runtime/bin/python3"
        runtime_app.parent.mkdir(parents=True)
        self.app.rename(runtime_app)
        loader_script = SUBJECT.with_name("bundle-loader.sh")
        subprocess.run(["bash", str(loader_script), "--beside", "--external-library-path", str(self.bundle),
                        str(directory), "runtime/bin/python3"], check=True, stdout=subprocess.DEVNULL)
        return runtime_app

    def test_real_dynamic_elf_and_bundled_glibc(self):
        output = subprocess.run(["readelf", "-VW", str(self.app)], text=True, capture_output=True, check=True).stdout
        expected = {(int(major), int(minor)) for major, minor in re.findall(r"Name: GLIBC_(\d+)\.(\d+)", output)}
        self.assertEqual(set(module.glibc_versions(self.app)), expected)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"libc6 \(>= 2\.\d+\)")
        (self.bundle / "bundle.json").write_text(json.dumps({"glibc": True}))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "libc6")

    def test_relr_requires_glibc_236_and_unknown_abi_fails_closed(self):
        source = self.root / "relr.c"
        source.write_text('#include <unistd.h>\nstatic const char s[]="ok\\n"; '
                          'static const char *p=s; void _start(void) { write(1,p,3); _exit(0); }\n')
        result = subprocess.run(["cc", "-nostartfiles", "-fPIE", "-pie", "-Wl,-z,pack-relative-relocs",
                                 str(source), "-o", str(self.app)], check=False, capture_output=True, text=True)
        if "pack-relative-relocs ignored" in result.stderr or (result.returncode and "unrecognized option" in result.stderr):
            self.skipTest("linker lacks packed relative relocations: " + result.stderr.strip())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.app)], check=True, capture_output=True, text=True).stdout, "ok\n")
        self.assertIn((2, 36), module.glibc_versions(self.app))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("libc6 (>= 2.36)", result.stdout)
        original = self.app.read_bytes()
        self.assertIn(b"GLIBC_ABI_DT_RELR\0", original)
        elf = module.ElfSections(self.app)
        section = next(item for item in elf.sections if item[0] == module.SECTION_DYNAMIC)
        fmt = elf.endian + ("qQ" if elf.bits == 2 else "iI")
        size = struct.calcsize(fmt)
        data = bytearray(original)
        changed = []
        for offset in range(section[1], section[1] + section[2], size):
            tag, _ = struct.unpack_from(fmt, data, offset)
            if tag in (35, 36, 37):
                struct.pack_into(elf.endian + ("q" if elf.bits == 2 else "i"), data, offset, 0x70000000 + tag)
                changed.append(tag)
        self.assertEqual(sorted(changed), [35, 36, 37])
        elf.stream.close()
        self.app.write_bytes(data)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("libc6 (>= 2.36)", result.stdout)
        self.app.write_bytes(original.replace(b"GLIBC_ABI_DT_RELR\0", b"GLIBC_ABI_XX_RELR\0"))
        result = self.run_subject()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown glibc ABI version GLIBC_ABI_XX_RELR", result.stderr)
        self.assertIn((2, 36), module.glibc_versions(self.app, require_host=False))
        self.app.write_bytes(original.replace(b"GLIBC_ABI_DT_RELR\0", b"GLIBC_2.2.5\0" + b"\0" * 6))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("libc6 (>= 2.36)", result.stdout)
        elf = module.ElfSections(self.app)
        section = next(item for item in elf.sections if item[0] == module.SECTION_DYNAMIC)
        fmt = elf.endian + ("qQ" if elf.bits == 2 else "iI")
        size = struct.calcsize(fmt)
        data = bytearray(original)
        for offset in range(section[1], section[1] + section[2], size):
            tag, _ = struct.unpack_from(fmt, data, offset)
            if tag == 35:
                struct.pack_into(elf.endian + ("q" if elf.bits == 2 else "i"), data, offset, 0x70000000)
                break
        else:
            self.fail("fixture has no DT_RELRSZ")
        elf.stream.close()
        self.app.write_bytes(data)
        result = self.run_subject()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid ELF DT_RELR entries", result.stderr)

    def test_readelf_failure_and_silent_truncation_rejected(self):
        real = shutil.which("readelf")
        for script in ("exit 1", "exit 0", f'"{real}" "$@" | head -n 5'):
            with self.subTest(script=script):
                self.fake_tool("readelf", script)
                self.assertNotEqual(self.run_subject().returncode, 0)

    def test_ldconfig_empty_and_truncated_rejected(self):
        real = shutil.which("ldconfig")
        for script in ("exit 1", "exit 0", f'"{real}" "$@" | head -n 3'):
            with self.subTest(script=script):
                self.fake_tool("ldconfig", script)
                self.assertNotEqual(self.run_subject().returncode, 0)

    def test_missing_owner_and_dependency_are_rejected(self):
        self.fake_tool("dpkg", "exit 0")
        self.assertNotEqual(self.run_subject().returncode, 0)
        (self.fake / "dpkg").unlink()
        subprocess.run(["patchelf", "--add-needed", "libmissing-example.so.1", str(self.app)], check=True)
        result = self.run_subject()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libmissing-example.so.1", result.stderr)

    def test_dynamic_strings_must_match_the_load_segments(self):
        elf = module.ElfSections(self.app)
        section = next(item for item in elf.sections if item[0] == module.SECTION_DYNAMIC)
        strings = elf.sections[section[3]]
        data = elf.data(strings)
        entries, _ = module.dynamic_entries(elf)
        address = next(value for tag, value in entries if tag == 5)
        elf.load_segments.append((address + 2, address + 4, strings[1] + 2))
        with self.assertRaisesRegex(ValueError, "ambiguous ELF loader mapping"):
            elf.loader_bytes(address, len(data))
        section_header = elf.section_table + section[3] * elf.section_size
        offset_field = section_header + (24 if elf.bits == 2 else 16)
        offset_format = elf.endian + ("Q" if elf.bits == 2 else "I")
        elf.stream.close()
        original = self.app.read_bytes()
        duplicate_offset = len(original)
        altered = bytearray(original + data)
        struct.pack_into(offset_format, altered, offset_field, duplicate_offset)
        self.app.write_bytes(altered)
        valid = self.run_subject()
        self.assertEqual(valid.returncode, 0, valid.stderr)
        index = data.find(b"libc.so.6\0")
        self.assertGreaterEqual(index, 0)
        altered[duplicate_offset + index:duplicate_offset + index + 10] = b"libz.so.1\0"
        self.app.write_bytes(altered)
        runtime = subprocess.run([str(self.app)], capture_output=True, text=True, check=True)
        self.assertEqual(runtime.stdout.strip(), "test")
        self.assertIn("libz.so.1", module.needed(self.app))
        result = self.run_subject()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dynamic strings differ from loader mapping", result.stderr)

    def test_dynamic_entries_must_match_the_load_segments(self):
        elf = module.ElfSections(self.app)
        section = next(item for item in elf.sections if item[0] == module.SECTION_DYNAMIC)
        address = elf.section_address(elf.sections.index(section))
        field = elf.section_table + elf.sections.index(section) * elf.section_size + (16 if elf.bits == 2 else 12)
        encoding = elf.endian + ("Q" if elf.bits == 2 else "I")
        elf.stream.close()
        with self.app.open("r+b") as stream:
            stream.seek(field)
            stream.write(struct.pack(encoding, address + 1))
        result = self.run_subject()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dynamic entries differ from loader mapping", result.stderr)

    def test_version_needs_must_match_the_load_segments(self):
        elf = module.ElfSections(self.app)
        section = next(item for item in elf.sections if item[0] == module.SECTION_NEED)
        data = elf.data(section)
        strings = elf.data(elf.sections[section[3]])
        _, count, _, auxiliary, _ = elf.unpack("HHIII", data)
        names = []
        for _ in range(count):
            _, _, _, name, following = elf.unpack("IHHII", data, auxiliary)
            names.append((auxiliary, name, module.version_name(elf, strings, name)))
            auxiliary += following
        self.assertGreaterEqual(len(names), 2)
        newest = max(names, key=lambda item: tuple(int(value) for value in item[2].removeprefix("GLIBC_").split(".")))
        oldest = min(names, key=lambda item: tuple(int(value) for value in item[2].removeprefix("GLIBC_").split(".")))
        field = elf.section_table + elf.sections.index(section) * elf.section_size + (24 if elf.bits == 2 else 16)
        encoding = elf.endian + ("Q" if elf.bits == 2 else "I")
        elf.stream.close()
        original = self.app.read_bytes()
        altered = bytearray(original + data)
        struct.pack_into(encoding, altered, field, len(original))
        self.app.write_bytes(altered)
        valid = self.run_subject()
        self.assertEqual(valid.returncode, 0, valid.stderr)
        struct.pack_into(elf.endian + "I", altered, len(original) + newest[0] + 8, oldest[1])
        self.app.write_bytes(altered)
        self.assertEqual(subprocess.run([str(self.app)], capture_output=True, text=True, check=True).stdout.strip(), "test")
        version_output = subprocess.run(["readelf", "-VW", str(self.app)], capture_output=True, text=True, check=True).stdout
        self.assertNotIn("Name: " + newest[2], version_output)
        result = self.run_subject()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version needs differ from loader mapping", result.stderr)

    def test_unreachable_and_origin_reachable_library(self):
        source = module.ldconfig_cache()["libz.so.1"]
        owner = module.package_owner(source)
        self.assertTrue(owner)
        subprocess.run(["patchelf", "--add-needed", "libz.so.1", str(self.app)], check=True)
        directory = self.bundle / "unrelated"
        directory.mkdir()
        shutil.copyfile(source, directory / "libz.so.1")
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        subprocess.run(["patchelf", "--set-rpath", "$ORIGIN/unrelated", str(self.app)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(owner, result.stdout)
    def test_gpu_launcher_library_path_and_waived_provider(self):
        source = module.ldconfig_cache()["libz.so.1"]
        owner = module.package_owner(source)
        self.assertTrue(owner)
        subprocess.run(["patchelf", "--add-needed", "libz.so.1", str(self.app)], check=True)
        directory = self.bundle / "runtime/lib"
        directory.mkdir(parents=True)
        shutil.copyfile(source, directory / "libz.so.1")
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        (self.bundle / "bundle.json").write_text(json.dumps({"glibc": False, "host_gpu_sonames": ["libcuda.so.1"]}))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        runtime_app = self.bundle / "runtime/bin/python3"
        runtime_app.parent.mkdir(parents=True)
        self.app.rename(runtime_app)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        loader_script = SUBJECT.with_name("bundle-loader.sh")
        subprocess.run(["bash", str(loader_script), "--beside", "--external-library-path", str(self.bundle),
                        str(directory), "runtime/bin/python3"], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(directory / "glibc")
        for bundled in ("", "1"):
            env = {"PATH": "/usr/bin:/bin", "KATAGLYPHIS_BUNDLED_GLIBC": bundled, "LD_DEBUG": "libs"}
            execution = subprocess.run([str(runtime_app)], env=env, check=True, text=True, capture_output=True)
            self.assertIn("/lib/libz.so.1", execution.stderr)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(owner, result.stdout)

    def test_gpu_unwrapped_executable_keeps_host_library_dependency(self):
        source = module.ldconfig_cache()["libz.so.1"]
        owner = module.package_owner(source)
        directory = self.bundle / "runtime/lib"
        directory.mkdir(parents=True)
        shutil.copyfile(source, directory / "libz.so.1")
        (self.bundle / "bundle.json").write_text(json.dumps({"glibc": False, "host_gpu_sonames": ["libcuda.so.1"]}))
        self.make_gpu_wrapper(directory)
        shutil.rmtree(directory / "glibc")
        self.assertTrue(module.gpu_launcher_ready(self.bundle))
        library_source = self.root / "consumer.c"
        library_source.write_text('extern const char *zlibVersion(void); const char *fixture(void) { return zlibVersion(); }\n')
        library = directory / "libfixture.so"
        subprocess.run(["cc", "-shared", "-fPIC", str(library_source), "-Wl,-soname,libfixture.so", "-l:libz.so.1",
                        "-o", str(library)], check=True)
        executable_source = self.root / "standalone.c"
        executable_source.write_text('#include <stdio.h>\n#include <string.h>\nextern const char *fixture(void);\n'
                                     'int main(void) { char line[4096]; FILE *f = fopen("/proc/self/maps", "r"); '
                                     'if (!f || !fixture()) return 1; while (fgets(line, sizeof(line), f)) '
                                     'if (strstr(line, "libz.so")) fputs(line, stdout); return 0; }\n')
        executable = self.bundle / "bin/direct"
        executable.parent.mkdir()
        subprocess.run(["cc", str(executable_source), "-L" + str(directory), "-l:libfixture.so",
                        "-Wl,-rpath,$ORIGIN/../runtime/lib", "-o", str(executable)], check=True)
        environment = dict(os.environ)
        environment.pop("LD_LIBRARY_PATH", None)
        environment.pop("LD_PRELOAD", None)
        actual = subprocess.run([str(executable)], env=environment, check=True, capture_output=True, text=True)
        self.assertIn(os.path.realpath(source), actual.stdout)
        self.assertNotIn(str(directory / "libz.so.1"), actual.stdout)
        self.assertFalse(module.gpu_launcher_ready(self.bundle))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)

    def test_python_preload_requires_sitecustomize_and_bundle_library(self):
        source = module.ldconfig_cache()["libz.so.1"]
        owner = module.package_owner(source)
        directory = self.bundle / "runtime/lib"
        site = directory / "python3.14/site-packages"
        site.mkdir(parents=True)
        shutil.copyfile(source, directory / "libz.so.1")
        (directory / "preload.list").write_text("libz.so.1\n")
        module_file = site / "extension.so"
        source_file = self.root / "extension.c"
        source_file.write_text("int fixture(void) { return 1; }\n")
        subprocess.run(["cc", "-shared", "-fPIC", str(source_file), "-o", str(module_file)], check=True)
        subprocess.run(["patchelf", "--add-needed", "libz.so.1", str(module_file)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        (site / "sitecustomize.py").write_text(module.SITE_CUSTOMIZE)
        self.app.unlink()
        runtime = self.bundle / "runtime/bin/python3.14"
        runtime.parent.mkdir(parents=True)
        probe_source = self.root / "probe.c"
        proof = json.dumps([str(self.bundle / "runtime"), str(site / "sitecustomize.py"), 1, 0, 1, [str(site)],
                            [str(directory / "libz.so.1")]])
        probe_source.write_text(f'#include <stdio.h>\nint main(void) {{ puts({json.dumps(proof)}); }}\n')
        subprocess.run(["cc", str(probe_source), "-o", str(runtime)], check=True)
        runtime.with_name("python3").symlink_to("python3.14")
        loader_script = SUBJECT.with_name("bundle-loader.sh")
        subprocess.run(["bash", str(loader_script), "--beside", str(self.bundle), str(directory),
                        "runtime/bin/python3.14"], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(directory / "glibc")
        launcher = self.bundle / "bin/fixture"
        launcher.parent.mkdir()
        launcher.write_text('''#!/bin/sh
# fixture launcher
here=$(dirname "$(readlink -f "$0")")
root=$(dirname "$here")
export DATA_DIR="$root/share/fixture"

exec "$root/runtime/bin/python3" -I -B -c 'import sys; sys.argv[0] = "fixture"; from fixture import main as _entry; sys.exit(_entry())' "$@"
''')
        (self.bundle / "bundle.json").write_text(json.dumps({"glibc": False, "scripts": ["fixture"]}))
        self.assertTrue(module.isolated_entry_ready(self.bundle, "fixture"))
        self.assertTrue(module.isolated_interpreter_ready(self.bundle))
        command = 'import sys,ctypes; sys.prefix=sys.argv[1]; exec(open(sys.argv[2]).read()); ctypes.CDLL(sys.argv[3])'
        subprocess.run(["python3", "-I", "-S", "-c", command, str(self.bundle / "runtime"),
                        str(site / "sitecustomize.py"), str(module_file)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(owner, result.stdout)
        self.assert_preload_pth_scope(site, module_file, source, directory, owner)
        self.assert_probe_mutations(site, source, directory, owner, runtime, probe_source)
        original = launcher.read_text()
        launcher.write_text(original.replace(" -I -B ", " -B "))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        launcher.write_text(original)
        interpreter = runtime.read_text()
        runtime.write_text(interpreter.replace('"$@"', '"$@"; true', 1))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        (directory / "libz.so.1").unlink()
        (self.bundle / "bundle.json").write_text(json.dumps({"glibc": False, "unresolved_allowed": ["libz.so.1"]}))
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(owner, result.stdout)

    def assert_probe_mutations(self, site, source, directory, owner, runtime, probe_source):
        binary = runtime.with_name("python3.14.bin")
        original_binary = binary.read_bytes()
        wrong_proof = json.dumps([str(self.bundle / "runtime"), str(site / "sitecustomize.py"), 0, 0, 1, [str(site)],
                                  [str(directory / "libz.so.1")]])
        probe_source.write_text(f'#include <stdio.h>\nint main(void) {{ puts({json.dumps(wrong_proof)}); }}\n')
        subprocess.run(["cc", str(probe_source), "-o", str(binary)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        conflicting = json.dumps([str(self.bundle / "runtime"), str(site / "sitecustomize.py"), 1, 0, 1,
                                  [str(site)], [str(directory / "libz.so.1"), source]])
        probe_source.write_text(f'#include <stdio.h>\nint main(void) {{ puts({json.dumps(conflicting)}); }}\n')
        subprocess.run(["cc", str(probe_source), "-o", str(binary)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        binary.write_bytes(original_binary)
        preload = directory / "libz.so.1"
        original_preload = preload.read_bytes()
        subprocess.run(["patchelf", "--set-soname", "libz-wrong.so.1", str(preload)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        preload.write_bytes(original_preload)

    def assert_preload_pth_scope(self, site, module_file, source, directory, owner):
        other_site = directory / "python3.13/site-packages"
        other_site.mkdir(parents=True)
        (other_site / "sitecustomize.py").write_text(module.SITE_CUSTOMIZE)
        self.assertFalse(module.python_preloads_active(self.bundle, other_site / "extension.so"))
        standalone = self.bundle / "bin/standalone"
        source_file = self.root / "standalone-preload.c"
        source_file.write_text('#include <dlfcn.h>\n#include <stdio.h>\n#include <string.h>\n'
                               'int main(int argc, char **argv) { char line[4096]; '
                               'if (argc != 2 || !dlopen(argv[1], RTLD_NOW)) return 1; '
                               'FILE *f = fopen("/proc/self/maps", "r"); if (!f) return 1; '
                               'while (fgets(line, sizeof(line), f)) if (strstr(line, "libz.so")) fputs(line, stdout); '
                               'return 0; }\n')
        subprocess.run(["cc", str(source_file), "-ldl", "-o", str(standalone)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        standalone.unlink()
        linked = directory / "linked-site"
        linked.symlink_to(other_site, target_is_directory=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(owner, result.stdout)
        linked.unlink()
        (site / "early.pth").write_text("# passive path\noptional-directory\n")
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(owner, result.stdout)
        (site / "early_loader.py").write_text(f"import ctypes\nhandle = ctypes.CDLL({str(module_file)!r})\n")
        for payload in (b"import early_loader\n", b"import\tearly_loader\n", b"\xef\xbb\xbfimport early_loader\n", b"\xff\n"):
            with self.subTest(payload=payload):
                (site / "early.pth").write_bytes(payload)
                result = self.run_subject()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(owner, result.stdout)
        (site / "early.pth").write_text("import early_loader\n")
        early = ('import os,site,sys; sys.prefix=sys.argv[1]; site.addsitedir(sys.argv[2]); '
                 'exec(open(sys.argv[5]).read()); paths=open("/proc/self/maps").read(); '
                 'assert os.path.realpath(sys.argv[3]) in paths and os.path.realpath(sys.argv[4]) in paths, '
                 '[(os.path.realpath(p), os.path.realpath(p) in paths) for p in sys.argv[3:]]')
        subprocess.run(["python3", "-I", "-S", "-c", early, str(self.bundle / "runtime"), str(site),
                        source, str(directory / "libz.so.1"), str(site / "sitecustomize.py")], check=True)
        (site / "early.pth").unlink()

    def test_elf_version_table_mismatch_and_truncation_rejected(self):
        elf = module.ElfSections(self.app)
        section = next(item for item in elf.sections if item[0] == module.SECTION_NEED)
        elf.stream.close()
        original = self.app.read_bytes()
        with self.app.open("r+b") as stream:
            stream.seek(section[1] + 2)
            stream.write(struct.pack(elf.endian + "H", 65535))
        self.assertNotEqual(self.run_subject().returncode, 0)
        self.app.write_bytes(original)
        with self.app.open("r+b") as stream:
            # Zero the version-needs section type while DT_VERNEEDNUM still requires it.
            header = original[:64]
            section_offset = struct.unpack_from(elf.endian + ("Q" if elf.bits == 2 else "I"), header, 40 if elf.bits == 2 else 32)[0]
            section_size = struct.unpack_from(elf.endian + "H", header, 58 if elf.bits == 2 else 46)[0]
            section_index = elf.sections.index(section)
            stream.seek(section_offset + section_index * section_size + 4)
            stream.write(bytes(4))
        for bundled in (False, True):
            with self.subTest(bundled_glibc=bundled):
                (self.bundle / "bundle.json").write_text(json.dumps({"glibc": bundled}))
                result = self.run_subject()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("version sections do not match", result.stderr)

    def test_static_elf_is_valid(self):
        source = self.root / "static.c"
        source.write_text("void _start(void) { for (;;) {} }\n")
        subprocess.run(["cc", "-nostdlib", "-static", str(source), "-o", str(self.app)], check=True)
        result = self.run_subject()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "libc6 (>= 2.17)")


if __name__ == "__main__":
    unittest.main()
