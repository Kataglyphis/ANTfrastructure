# Windows Reference (general)

General Windows and PowerShell commands — the ones that get looked up,
forgotten and looked up again.

**This page is different from the rest of `docs/`.** Everywhere else, an entry
exists because something in this repo's lanes broke and the fix is recorded with
its incident. Here the entries are ordinary Windows knowledge: correct, useful,
and *not* specific to this repo. Nothing on this page is verified against a
build lane, so do not treat it with the same authority as
[Fresh Windows Host Bring-Up](windows-host-setup.md) or
[Windows Build Image](windows-builds.md).

If an entry here turns out to be load-bearing for a lane, move it to the owning
page in [`INDEX.md`](INDEX.md) and give it the *why*. This page's Linux
counterpart is [Linux Reference](linux-reference.md).

---

## Disk and files

Largest files under a directory:

```powershell
Get-ChildItem 'C:\path\to\folder' -Recurse -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending |
  Select-Object FullName, @{Name='SizeMB'; Expression={ [math]::Round($_.Length / 1MB, 2) }} -First 10 |
  Format-Table -AutoSize
```

Folder sizes, recursively:

```powershell
Get-ChildItem -Path $root -Directory -Recurse |
  ForEach-Object {
    $size = (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    [PSCustomObject]@{ Folder = $_.FullName; SizeMB = [math]::Round($size / 1MB, 2) }
  } | Sort-Object SizeMB -Descending
```

Free space per volume:

```powershell
Get-CimInstance Win32_LogicalDisk |
  Select-Object DeviceID,
    @{Name='FreeGB'; Expression={ [math]::Round($_.FreeSpace / 1GB, 2) }},
    @{Name='SizeGB'; Expression={ [math]::Round($_.Size / 1GB, 2) }}
```

> Reclaiming space on a build host goes through
> `windows\scripts\host\free-disk-space.ps1`, which works from an allowlist and
> is report-only by default. Prefer it over ad-hoc recursive deletes.

Long paths are a build-host concern and are covered in
[Fresh Windows Host Bring-Up](windows-host-setup.md) — including the registry
switch and `robocopy /E /MOVE` for relocating a tree that has become too deep to
handle normally.

## Running things and reading the result

Scope an execution-policy bypass to the session, not the machine:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Capture output to the console *and* a file, then check the real exit status —
the first thing to do when an executable "just doesn't start":

```powershell
.\yourapp.exe 2>&1 | Tee-Object -FilePath .\run_output.txt
Write-Output "exit code: $LASTEXITCODE"
```

`$LASTEXITCODE` is the native process's code; `$?` is PowerShell's own view and
will not tell you what a crashing exe returned.

List a directory compactly:

```powershell
Get-ChildItem -Path .\logs\ | Format-Table Name, Length
```

Count lines of code, skipping the usual noise:

```powershell
Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '(\.git|node_modules|venv|build|dist|archive|ExternalLib)' } |
  Where-Object { $_.Extension -match '^\.(c|cpp|h|hpp|py|rs|java|js|ts|go|dart|sh|ps1)$' } |
  ForEach-Object { ([System.IO.File]::ReadLines($_.FullName) | Measure-Object -Line).Lines } |
  Measure-Object -Sum | Select-Object -ExpandProperty Sum
```

Swap a CSV delimiter:

```powershell
(Get-Content input.csv) -replace ',', ';' | Set-Content output.csv -Encoding UTF8
```

## Services and updates

```powershell
Get-Service | Where-Object Status -eq 'Running'
Restart-Service -Name <name>
```

Windows Update from a shell (needs the `PSWindowsUpdate` module):

```powershell
Import-Module PSWindowsUpdate
Install-WindowsUpdate -AcceptAll -AutoReboot
```

Package management, Visual Studio updates and pinning an exact SDK version are
in [Fresh Windows Host Bring-Up § Appendix](windows-host-setup.md#appendix--host-odds-and-ends).

## Restart, shutdown, recovery

```cmd
shutdown /r /t 0
shutdown /s /t 0
```

```powershell
Restart-Computer -Force
```

To reach the recovery environment when the OS will not boot normally: start
Windows and interrupt it during the load phase three times in a row. It then
offers recovery options on the next boot.

## PATH

Temporarily, in a `cmd` session:

```cmd
set PATH=C:\tools\bin;%PATH%
```

Picking up a machine-level PATH change in an already-open PowerShell session,
without logging out, is in
[Fresh Windows Host Bring-Up § Appendix](windows-host-setup.md#appendix--host-odds-and-ends).

## SSH into a Windows host

Enable **OpenSSH Server** in Optional Features, then:

- system-wide config: `%ProgramData%\ssh\sshd_config`
- per-user config: `%UserProfile%\.ssh\config`
- authorized keys: `C:\Users\<user>\.ssh\authorized_keys`

In `sshd_config`, uncomment what you actually want:

```
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
```

```powershell
Restart-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

> Turn `PasswordAuthentication` off once keys work. On a machine reachable from
> anything wider than your own LAN, password auth is the exposure, not the
> convenience.

Client-side key handling — `ssh-keygen`, `ssh-copy-id`, the agent, clearing a
stale host key after a reflash — is in
[Linux Reference § SSH](linux-reference.md#ssh) and applies unchanged from a
Windows client.

## Wake-on-LAN

Three layers all have to agree, which is why this fails silently so often.

**1. Adapter** — Device Manager → the NIC → Advanced:

| Property | Value |
|---|---|
| Enable PME | Enabled |
| Energy Efficient Ethernet | Off |
| Wait for Link | On |
| Wake on Link Settings | Forced |
| Wake on Magic Packet | Enabled |
| Wake on Pattern Match | Enabled |

**2. Power options** — disable Fast Startup, and disable sleep/hibernate if the
machine must stay reachable.

**3. Firmware** — disable Fast Boot, enable UEFI, and enable whatever the board
calls wake-from-PCIe. Observed here: WoL stopped working after a **CPU swap**,
because the CMOS reset took "Power On by PCI-E" with it. If WoL worked and then
stopped after any hardware change, check firmware before anything else.

## Certificates and MSIX

Generating and importing an MSIX signing certificate is owned by
[`windows/scripts/certificates/README.md`](../windows/scripts/certificates/README.md)
and the `WindowsMsix.*` modules. One consumer-side step that is easy to miss:
**Developer Mode must be enabled** (Settings → System → For developers) before
Windows will install a self-signed `.msix`, even once the certificate is
trusted.

## Toolchain odds and ends

Check which ABI a `clang` build targets — the clang-cl lane is MSVC-ABI, and a
mingw-flavoured clang is not interchangeable with it:

```cpp
#include <iostream>
int main() {
#ifdef _MSC_VER
    std::cout << "MSVC ABI\n";
#elif defined(__GNUC__)
    std::cout << "GNU ABI\n";
#endif
}
```

```powershell
& "C:\Program Files\LLVM\bin\clang++.exe" -v test.cpp -o test.exe
```

Format Dart sources to the project's line length:

```powershell
dart format --line-length 80 .
```

If `dart format` produces errors that make no sense, reinstall the SDK — a
partially-extracted SDK fails here rather than at install time. The ARM variant
of the same trap (a stale `cache` directory) is in
[Linux Host Setup § D2](linux-host-setup.md#d2-flutter-on-arm-hosts).

## Phantom programs and drivers

Removing a driver that will not uninstall (`pnputil`) is in
[Fresh Windows Host Bring-Up § Appendix](windows-host-setup.md#appendix--host-odds-and-ends).

A program that shows in the installed list but cannot be uninstalled has left an
orphaned registry entry. Open `regedit` as admin and clear its key from
whichever of these holds it:

```
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
```

## Removable media

An SD card or USB stick reporting the wrong capacity usually has a leftover
partition table from a flashed image. Rufus handles this with less risk of
picking the wrong device; `diskpart` is the manual route:

```
diskpart
  list disk
  select disk X          ← identify by SIZE, and check twice
  clean
  create partition primary
  format fs=exfat quick
  exit
```

`select` followed by `clean` acts on whatever disk number you gave it, with no
confirmation. Getting the number wrong destroys the wrong volume.

## Media capture

Enumerate DirectShow devices and what they support:

```powershell
ffmpeg -list_devices true -f dshow -i dummy
ffmpeg -f dshow -list_options true -i video="<device name>"
```

Record from a device, and capture the screen:

```powershell
ffmpeg -f dshow -video_size 1920x1080 -framerate 30 -pixel_format yuyv422 `
  -i video="<device name>" -c:v libx264 -preset veryfast -crf 23 out.mp4

ffmpeg -video_size 1920x1080 -framerate 30 -f gdigrab -rtbufsize 100M `
  -i desktop -c:v libx264 -preset ultrafast -crf 23 screen.mp4
```

Trim both ends without working out the duration by hand:

```powershell
$duration = [double](ffprobe -v error -show_entries format=duration -of csv=p=0 "input.mp4")
$skip = 20
$tail = 7
$keep = [math]::Round($duration - ($skip + $tail), 3)
ffmpeg -ss $skip -i "input.mp4" -t $keep -c:v libx264 -c:a aac "output.mp4"
```

Resize an image, keeping aspect ratio:

```powershell
ffmpeg -i "input.png" -vf "scale=800:-1" -y "output.png"
```

A quick local preview straight from a capture device, useful for confirming a
camera works before wiring it into a pipeline:

```powershell
gst-launch-1.0 mfvideosrc device-index=0 ! video/x-raw,width=1280,height=720,framerate=60/1 `
  ! videoconvert ! autovideosink sync=false
```

The full WebRTC and v4l2 pipelines are in
[Runtime Services](runtime-services.md).

Format conversion, trimming, frame extraction and OCR pre-processing are
OS-agnostic and live in
[Linux Reference § Media and document conversion](linux-reference.md#media-and-document-conversion).
