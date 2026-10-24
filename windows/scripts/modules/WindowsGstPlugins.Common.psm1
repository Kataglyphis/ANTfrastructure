#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Merge-lane leaf, never in the media-builder buildmods: see docs/windows-build-resources.md § The Windows cache, tier by tier

Set-StrictMode -Version Latest

# Arch filtering lives in the contract, never at a call site: see docs/windows-build-invariants.md § The mandatory GStreamer plugin set is a contract
$gstTargetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if (Test-Path $gstTargetArchPath) {
    Import-Module $gstTargetArchPath -ErrorAction Stop
} else {
    throw ("WindowsGstPlugins.Common: required sibling module not found at $gstTargetArchPath. " +
           'Get-RequiredGstPlugin filters the contract per target arch and cannot answer correctly ' +
           'without it. Add WindowsTargetArch.Common.psm1 to the COPY list that carries this module.')
}

# Keep one private template so callers cannot alter the next build or smoke gate's contract.
$script:RequiredGstPluginContract = @(
        [pscustomobject]@{
            Name      = 'libav'
            Provides  = 'avdec_* / avenc_* / avmux_* — the FFmpeg codec bridge'
            Detection = 'pkg-config'
            NeedsPc   = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')
            Why       = 'the single largest codec surface in the image; without it GStreamer decodes almost nothing this build claims to support'
            # FFmpeg is cross-built for every target this repo supports.
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'opencv'
            Provides  = 'cvtracker, cvdilate, cvlaplace, faceblur, … CV filter elements'
            Detection = 'pkg-config'
            NeedsPc   = @('opencv4')
            Why       = 'the reason OpenCV 5 is built from source into this image at all — the CV pipeline elements are the consumer'
            # OpenCV 5 is cross-built for aarch64 (NEON HAL included).
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'onnx'
            Provides  = 'onnxinference — ONNX Runtime inference inside a pipeline'
            Detection = 'pkg-config'
            NeedsPc   = @('libonnxruntime')
            Why       = 'the inference path of the media stack; ORT is built with CUDA/DML/TensorRT EPs specifically so pipelines can use it'
            # ORT is cross-built for aarch64; the plugin needs only libonnxruntime, not CUDA or DML.
            UnavailableOn = @{}
        },
        # Meson-native subprojects: nothing to pre-flight, so the post-build DLL and gst-inspect gate proves them.
        [pscustomobject]@{
            Name      = 'webrtc'
            Provides  = 'webrtcbin — WebRTC peer connection inside a pipeline (gst-plugins-bad ext/webrtc)'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-bad:webrtc'
            Why       = 'the only contract plugin that was silently lane-specific; a WebRTC pipeline on the arm64 bundle would have had no webrtcbin'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'nice'
            Provides  = 'nicesrc / nicesink — ICE transport for webrtcbin (libnice gstreamer plugin)'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'libnice:gstreamer'
            Why       = 'webrtcbin cannot negotiate a connection without the ICE elements'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'tflite'
            Provides  = 'tfliteinference — TensorFlow Lite / LiteRT inference inside a pipeline'
            Detection = 'compiler'
            NeedsPc   = @()
            # ext/tflite probes the compiler for the pre-rename header, so LiteRT's tflite/ tree needs an alias.
            NeedsHeader = 'tensorflow/lite/c/c_api.h'
            NeedsLib    = @('tensorflowlite_c', 'tensorflow-lite')
            Why         = 'LiteRT is built from source into this image; without this plugin nothing in a GStreamer pipeline can use it'
            # Required on the cross lane too: a cross merge that fails to build it must go red.
            UnavailableOn = @{}
        },
        # webrtcbin loads these by element name at run time, so only a load probe sees one missing.
        [pscustomobject]@{
            Name      = 'dtls'
            Provides  = 'dtlsenc / dtlsdec / dtlssrtpenc / dtlssrtpdec — the DTLS-SRTP transport of every WebRTC session'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-bad:dtls'
            Why       = 'webrtcbin builds its transport from these elements, and the plugin imports the OpenSSL DLLs, which must ship beside it'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'srtp'
            Provides  = 'srtpenc / srtpdec — SRTP for every WebRTC media packet (libsrtp2)'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-bad:srtp'
            Why       = 'dtlssrtpenc and dtlssrtpdec wrap these; without them a session negotiates and then moves no media'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'sctp'
            Provides  = 'sctpenc / sctpdec — the SCTP association behind WebRTC data channels (internal usrsctp)'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-bad:sctp'
            Why       = 'webrtcbin needs it for create-data-channel and for any peer that offers an application m-line'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'rtpmanager'
            Provides  = 'rtpbin / rtpjitterbuffer / rtprtxsend — the RTP session machinery inside webrtcbin'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-good:rtpmanager'
            Why       = 'webrtcbin creates an rtpbin for its sessions and cannot start without one'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'openh264'
            Provides  = 'openh264enc / openh264dec — H.264 under a BSD licence; this build ships no x264'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-bad:openh264'
            Why       = 'the only H.264 encoder Server Core can run here, so the WebRTC video path depends on it'
            UnavailableOn = @{}
        },
        # gst-plugins-rs crates, built by cargo after meson installs the C plugins they link.
        [pscustomobject]@{
            Name      = 'rswebrtc'
            Provides  = 'webrtcsink / webrtcsrc and their signalling server (gst-plugins-rs net/webrtc)'
            Detection = 'cargo'
            NeedsPc   = @()
            CargoPackage = 'gst-plugin-webrtc'
            Why       = 'the WebRTC producer and consumer elements consumers stream with; webrtcbin alone needs an application around it'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'rsrtp'
            Provides  = 'rtpgccbwe and the Rust RTP payloaders (gst-plugins-rs net/rtp)'
            Detection = 'cargo'
            NeedsPc   = @()
            CargoPackage = 'gst-plugin-rtp'
            Why       = 'webrtcsink congestion control defaults to rtpgccbwe and runs uncontrolled without it'
            UnavailableOn = @{}
        }
    )

function Copy-GstPluginContractEntry {
    param([pscustomobject]$Entry)
    $properties = [ordered]@{}
    foreach ($property in $Entry.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [System.Collections.IDictionary]) {
            $copy = @{}
            foreach ($key in $value.Keys) { $copy[$key] = $value[$key] }
            $value = $copy
        } elseif ($value -is [array]) { $value = @($value) }
        $properties[$property.Name] = $value
    }
    return [pscustomobject]$properties
}

function Get-RequiredGstPlugin {
    # Each caller gets independent entries because build, smoke and healthcheck share this contract.
    [CmdletBinding()]
    param([string]$Arch = '')

    $gstArch = Get-WindowsTargetArch -Arch $Arch

    $contract = $script:RequiredGstPluginContract

    # A dropped entry is logged: a silent removal is how an image once shipped without plugins.
    $available = @($contract | Where-Object { -not $_.UnavailableOn.ContainsKey($gstArch) } | ForEach-Object { Copy-GstPluginContractEntry -Entry $_ })
    foreach ($dropped in @($contract | Where-Object { $_.UnavailableOn.ContainsKey($gstArch) })) {
        Write-Verbose "Get-RequiredGstPlugin: '$($dropped.Name)' is not required on $gstArch - $($dropped.UnavailableOn[$gstArch])"
    }
    return $available
}

function Write-PkgConfigFile {
    # Meson finds OpenCV and ORT only through .pc files they do not ship; forward slashes, as pkg-config escapes on '\'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,           # module name == <Name>.pc, what dependency() looks up
        [Parameter(Mandatory)][string]$Version,        # must satisfy the consumer's constraint
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$IncludeDir,
        [Parameter(Mandatory)][string]$LibDir,
        [Parameter(Mandatory)][string[]]$Library,      # link names WITHOUT extension
        [Parameter(Mandatory)][string]$PkgConfigDir,
        [string[]]$ExtraCflags = @(),
        # Read only via get_variable('prefix') (opencv's share/opencv4); pass the install root then, default LibDir.
        [string]$Prefix = ''
    )
    $fwd = { param($p) ($p -replace '\\', '/') }
    New-Item -ItemType Directory -Force -Path $PkgConfigDir | Out-Null
    $cflags = @($IncludeDir | Where-Object { $_ } | ForEach-Object { '-I' + (& $fwd $_) }) + $ExtraCflags
    $libs = @('-L' + (& $fwd $LibDir)) + @($Library | ForEach-Object { '-l' + $_ })
    $prefixVal = if ($Prefix) { & $fwd $Prefix } else { & $fwd $LibDir }
    $content = @(
        "prefix=$prefixVal",
        '',
        "Name: $Name",
        "Description: $Description",
        "Version: $Version",
        "Cflags: $($cflags -join ' ')",
        "Libs: $($libs -join ' ')"
    )
    $path = Join-Path $PkgConfigDir "$Name.pc"
    Set-Content -Path $path -Value $content -Encoding ascii
    Write-Host "Wrote pkg-config file: $path (Version $Version, $($Library.Count) lib(s))"
    return $path
}

function Get-LibraryLinkName {
    # Enumerated, not hardcoded: OpenCV's per-module .lib set changes with its module list.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibDir,
        [string]$Filter = '*.lib',
        # pkg-config has no config concept, and linking both flavours duplicates symbols.
        [switch]$ExcludeDebug
    )
    if (-not (Test-Path $LibDir)) { return @() }
    $libs = @(Get-ChildItem -Path $LibDir -Filter $Filter -File -ErrorAction SilentlyContinue |
            ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    if ($ExcludeDebug) { $libs = @($libs | Where-Object { $_ -notmatch 'd$' -or $_ -match '\dd?$' }) }
    return @($libs | Sort-Object -Unique)
}

function Assert-PkgConfigModule {
    # Before meson: a missing module otherwise becomes a silently skipped plugin an hour later.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Module,
        [string]$PkgConfigPath = $env:PKG_CONFIG_PATH,
        [string]$Context = 'GStreamer plugin integrations',
        # module -> minimum version the consumer demands; presence alone passes a .pc whose Version is "..".
        [hashtable]$MinimumVersion = @{}
    )
    if ($Module.Count -eq 0) { return }
    $pkgConfig = Get-Command pkg-config -ErrorAction SilentlyContinue
    if (-not $pkgConfig) {
        throw ("pkg-config is not on PATH, so $Context cannot be resolved at all. " +
            'It is installed by Install-ScoopTools.ps1 into the base image; a missing binary here means the base is wrong.')
    }
    $missing = @()
    $tooOld = @()
    foreach ($m in $Module) {
        $global:LASTEXITCODE = 0
        $null = & $pkgConfig.Source '--exists' $m 2>&1
        if ($LASTEXITCODE -ne 0) { $missing += $m; continue }
        $ver = (& $pkgConfig.Source '--modversion' $m 2>&1 | Select-Object -First 1)
        $wanted = $MinimumVersion[$m]
        if ($wanted) {
            # The same comparison meson would make, so a malformed version fails here.
            $global:LASTEXITCODE = 0
            $null = & $pkgConfig.Source "--atleast-version=$wanted" $m 2>&1
            if ($LASTEXITCODE -ne 0) {
                $tooOld += "$m (has '$ver', needs >= $wanted)"
                continue
            }
            Write-Host "  pkg-config OK: $m ($ver >= $wanted)"
        } else {
            Write-Host "  pkg-config OK: $m ($ver)"
        }
    }
    if ($missing.Count -gt 0) {
        throw ("pkg-config cannot resolve: $($missing -join ', ') — $Context WOULD BE SILENTLY SKIPPED by meson. " +
            "PKG_CONFIG_PATH=$PkgConfigPath. Fix the .pc emission (Write-PkgConfigFile) or the install layout; " +
            'do NOT relax the meson feature back to auto — that is what hid this for months.')
    }
    if ($tooOld.Count -gt 0) {
        throw ("pkg-config resolves these, but NOT at the version the consumer demands: $($tooOld -join '; '). " +
            "$Context would be silently skipped by meson. A version like '..' means the producing build never " +
            "determined its own version (FFmpeg does this when configure finds neither a VERSION file nor git " +
            'tags) — fix it at the producing stage, not by relaxing the constraint.')
    }
    $global:LASTEXITCODE = 0
}

function Get-GstRustCargoPlan {
    # The cargo build of the contract's cargo plugins, the environment it needs and the DLLs it leaves; see docs/windows-builds.md § gst-plugins-rs on Windows.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plugin,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$PkgConfigDir,
        [string]$Arch = '',
        [int]$Jobs = 0
    )
    $cargoPlugins = @($Plugin | Where-Object { $_.Detection -eq 'cargo' })
    if ($cargoPlugins.Count -eq 0) { throw 'Get-GstRustCargoPlan: no contract entry has Detection cargo, so there is nothing to build' }
    $gstArch = Get-WindowsTargetArch -Arch $Arch
    # --locked: upstream's Cargo.lock pins every crate and git dependency, and a re-resolve would ship crates nobody tested.
    $cargoArgs = @('build', '--release', '--locked', '--target-dir', $TargetDir)
    foreach ($p in $cargoPlugins) { $cargoArgs += @('-p', $p.CargoPackage) }
    if ($Jobs -gt 0) { $cargoArgs += @('--jobs', "$Jobs") }
    # No RUSTC_WRAPPER: 99 % Rust hits saved nothing, the plugin cdylibs are the step (docs/windows-builds.md § gst-plugins-rs on Windows).
    $cargoEnv = [ordered]@{ PKG_CONFIG_PATH = $PkgConfigDir }
    $outDir = Join-Path $TargetDir 'release'
    if (Test-WindowsCrossTarget -Arch $gstArch) {
        $triple = Get-RustTargetTriple -Arch $gstArch
        $cargoArgs += @('--target', $triple)
        $outDir = Join-Path $TargetDir "$triple\release"
        $tripleVar = $triple -replace '-', '_'
        # pkg-config-rs refuses a cross target without this, and PKG_CONFIG_PATH already names only the target's .pc files.
        $cargoEnv['PKG_CONFIG_ALLOW_CROSS'] = '1'
        $cargoEnv["CARGO_TARGET_$($tripleVar.ToUpperInvariant())_LINKER"] = 'lld-link'
        # ring compiles C and assembly for the target; only clang has the aarch64-windows assembler it needs.
        $cargoEnv["CC_$tripleVar"] = 'clang-cl'
        $cargoEnv["CFLAGS_$tripleVar"] = "--target=$(Get-ClangTargetTriple -Arch $gstArch)"
        $cargoEnv["AR_$tripleVar"] = 'llvm-lib'
    }
    $dlls = @($cargoPlugins | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; File = "gst$($_.Name).dll"; Path = Join-Path $outDir "gst$($_.Name).dll" }
    })
    return [pscustomobject]@{ Args = $cargoArgs; Env = $cargoEnv; OutDir = $outDir; Dlls = $dlls }
}

function Get-GstRustSourceMirrorConfig {
    # Cargo source replacement sending each locked gitlab.freedesktop.org git source to GStreamer's GitHub mirror; see docs/windows-builds.md § gst-plugins-rs on Windows.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CargoLock)
    $specs = [ordered]@{}
    foreach ($m in [regex]::Matches($CargoLock, 'source = "git\+(https://gitlab\.freedesktop\.org/gstreamer/([A-Za-z0-9._-]+?))(?:\.git)?\?(branch|tag|rev)=([^#"]+)#')) {
        $specs["$($m.Groups[1].Value)|$($m.Groups[3].Value)|$($m.Groups[4].Value)"] = $m
    }
    $toml = foreach ($m in $specs.Values) {
        $label = ("$($m.Groups[2].Value)-$($m.Groups[3].Value)-$($m.Groups[4].Value)" -replace '[^A-Za-z0-9-]', '-').ToLowerInvariant()
        $kind = $m.Groups[3].Value
        $value = $m.Groups[4].Value
        "[source.gitlab-$label]"
        "git = `"$($m.Groups[1].Value)`""
        "$kind = `"$value`""
        "replace-with = `"github-$label`""
        ''
        "[source.github-$label]"
        "git = `"https://github.com/GStreamer/$($m.Groups[2].Value)`""
        "$kind = `"$value`""
        ''
    }
    return (@($toml) -join "`n")
}

function Get-GstLoopbackTeardownError {
    # The frames arrived and only webrtcsrc's signaller failed while the pipeline tore down after EOS (BACKLOG CON68); empty for any other failure.
    param([string]$ConsumerOut, [string]$ConsumerErr, [int]$Frames, [int]$FrameRate = 30)
    if ($ConsumerOut -notmatch 'Got EOS from element "pipeline0"' -or $ConsumerErr -notmatch 'send failed because receiver is gone') { return @() }
    $elementErrors = @($ConsumerErr -split "`r?`n" | Where-Object { $_ -match '^ERROR: from element' })
    if (@($elementErrors | Where-Object { $_ -notmatch 'GstWebRTCSrc:webrtcsrc0' }).Count -gt 0) { return @() }
    # Nine fractional digits, two more than TimeSpan parses; frames flowing for less than Frames/FrameRate means EOS came early.
    if ($ConsumerOut -notmatch 'Execution ended after (\d+):(\d\d):(\d\d)\.(\d+)') { return @() }
    $seconds = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3] + [double]"0.$($Matches[4])"
    if ($seconds -lt 0.9 * $Frames / $FrameRate) { return @() }
    return @($elementErrors + @($ConsumerErr -split "`r?`n" | Where-Object { $_ -match 'receiver is gone' }))
}

function Wait-GstLoopbackReady {
    param($Producer, [datetime]$Deadline, [scriptblock]$Probe)
    $ready = $false
    while (-not $ready -and -not $Producer.HasExited -and [DateTime]::UtcNow -lt $Deadline) {
        $ready = [bool](& $Probe)
        if (-not $ready) { Start-Sleep -Milliseconds 250 }
    }
    return $ready
}

function Test-GstLoopbackReadiness {
    param($Producer, [ValidateSet('Port', 'Registration')][string]$Condition, [int]$Port, [string]$ProducerLogPath, [datetime]$Deadline)
    if ($Condition -eq 'Port') {
        $probe = {
            $client = [System.Net.Sockets.TcpClient]::new()
            try { return ($client.ConnectAsync('127.0.0.1', $Port).Wait(500) -and $client.Connected) }
            catch { return $false }
            finally { $client.Dispose() }
        }.GetNewClosure()
    } else {
        # The signalling port can listen before webrtcsink registers its producer.
        $readShared = { param([string]$Path) $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); try { [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() } }
        $probe = { (Test-Path -LiteralPath $ProducerLogPath) -and ((& $readShared $ProducerLogPath) -match 'registered as \[Producer\]') }.GetNewClosure()
    }
    return Wait-GstLoopbackReady -Producer $Producer -Deadline $Deadline -Probe $probe
}

function Add-GstLoopbackLogDetail {
    param($Result, [hashtable]$Logs, [string]$LogDir, [int]$Port)
    foreach ($name in 'consumer-err', 'consumer-out', 'producer-err', 'producer-out') {
        if (Test-Path $Logs[$name]) { $Result.Detail += @(Get-Content $Logs[$name] -Tail 12 | ForEach-Object { "${name}: $_" }) }
    }
    $Result.Detail += "full logs: $LogDir\webrtc-loopback-$Port-*.log"
}

function Set-GstLoopbackTeardownResult {
    param($Result, [hashtable]$Logs, [int]$Frames)
    if ($Result.ExitCode -eq 0 -or $Result.TimedOut -or -not (Test-Path $Logs['consumer-out']) -or -not (Test-Path $Logs['consumer-err'])) { return }
    $teardown = @(Get-GstLoopbackTeardownError -ConsumerOut (Get-Content -Raw $Logs['consumer-out']) `
            -ConsumerErr (Get-Content -Raw $Logs['consumer-err']) -Frames $Frames)
    if ($teardown.Count -gt 0) {
        $Result.TeardownError = $teardown
        $Result.ExitCode = 0
    }
}

function Invoke-GstWebRtcLoopback {
    # webrtcsink to webrtcsrc over the built-in signalling server on loopback; passes only when the consumer decodes -Frames frames and exits 0.
    [CmdletBinding()]
    param(
        [string]$GstLaunch = 'gst-launch-1.0',
        [int]$Frames = 60,
        [int]$TimeoutSeconds = 90,
        [string]$LogDir = $env:TEMP
    )
    $exe = (Get-Command $GstLaunch -ErrorAction Stop).Source
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    $producerArgs = 'videotestsrc is-live=true ! video/x-raw,format=I420,width=320,height=240,framerate=30/1 ! ' +
        "webrtcsink run-signalling-server=true signalling-server-host=127.0.0.1 signalling-server-port=$port video-caps=video/x-h264 meta=meta,name=smoke"
    # The capsfilter makes webrtcsrc depayload and decode; without it fakesink takes the RTP packets as they arrive.
    $consumerArgs = "-e webrtcsrc signaller::uri=ws://127.0.0.1:$port connect-to-first-producer=true ! video/x-raw ! queue ! identity eos-after=$Frames ! fakesink"
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logs = @{}
    foreach ($n in 'producer-out', 'producer-err', 'consumer-out', 'consumer-err') { $logs[$n] = Join-Path $LogDir "webrtc-loopback-$port-$n.log" }
    $producer = $null
    $consumer = $null
    $result = [pscustomobject]@{ ExitCode = -1; TimedOut = $false; Port = $port; Detail = @(); TeardownError = @() }
    # The WebRTC path at INFO: a pair that never connects (no ICE pair, no DTLS) otherwise stalls without a line (CON63, arm64).
    $callerDebug = $env:GST_DEBUG
    if (-not $callerDebug) { $env:GST_DEBUG = '2,webrtcsink:4,webrtcsrc:4,webrtcbin:4,nice:4,dtlsconnection:4' }
    try {
        $producer = Start-Process -FilePath $exe -ArgumentList $producerArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $logs['producer-out'] -RedirectStandardError $logs['producer-err']
        # Read once now: a Process started this way reports no ExitCode unless its handle was taken before it exited.
        $null = $producer.Handle
        if (-not (Test-GstLoopbackReadiness -Producer $producer -Condition Port -Port $port -Deadline ([DateTime]::UtcNow.AddSeconds(20)))) {
            $result.Detail = @("the producer's signalling server never listened on 127.0.0.1:$port (producer exited: $($producer.HasExited))")
            return $result
        }
        if (-not (Test-GstLoopbackReadiness -Producer $producer -Condition Registration -ProducerLogPath $logs['producer-out'] -Deadline ([DateTime]::UtcNow.AddSeconds(30)))) {
            $result.Detail = @("webrtcsink never registered as a producer with the signalling server on 127.0.0.1:$port (producer exited: $($producer.HasExited))")
            return $result
        }
        $consumer = Start-Process -FilePath $exe -ArgumentList $consumerArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $logs['consumer-out'] -RedirectStandardError $logs['consumer-err']
        $null = $consumer.Handle
        if ($consumer.WaitForExit($TimeoutSeconds * 1000)) {
            $consumer.WaitForExit()
            $result.ExitCode = $consumer.ExitCode
        } else {
            $result.TimedOut = $true
        }
    } finally {
        $env:GST_DEBUG = $callerDebug
        foreach ($p in @($consumer, $producer)) {
            if ($p -and -not $p.HasExited) { try { $p.Kill($true) } catch { Write-Verbose "loopback: kill failed: $($_.Exception.Message)" } }
        }
        Add-GstLoopbackLogDetail -Result $result -Logs $logs -LogDir $LogDir -Port $port
    }
    Set-GstLoopbackTeardownResult -Result $result -Logs $logs -Frames $Frames
    return $result
}

function Assert-GstWebRtcLoopback {
    # The image's smoke gate and the arm64 device gate both grade the loopback here; returns a teardown note (BACKLOG CON68) or ''.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$GstLaunch = 'gst-launch-1.0',
        [int]$Frames = 60,
        [int]$TimeoutSeconds = 90,
        [string]$LogDir = $env:TEMP
    )
    $r = Invoke-GstWebRtcLoopback -GstLaunch $GstLaunch -Frames $Frames -TimeoutSeconds $TimeoutSeconds -LogDir $LogDir
    if ($r.ExitCode -ne 0) {
        throw ("webrtcsrc did not decode $Frames frames from webrtcsink (consumer exit $($r.ExitCode)$(if ($r.TimedOut) { ', timed out' })): " +
            (@($r.Detail) -join ' | '))
    }
    if (@($r.TeardownError).Count -eq 0) { return '' }
    return "the frames arrived, then webrtcsrc's signaller failed in teardown (BACKLOG CON68): $(@($r.TeardownError) -join ' | ')"
}

Export-ModuleMember -Function Get-RequiredGstPlugin, Write-PkgConfigFile,
    Get-LibraryLinkName, Assert-PkgConfigModule, Get-GstRustCargoPlan, Get-GstRustSourceMirrorConfig, Invoke-GstWebRtcLoopback,
    Assert-GstWebRtcLoopback, Get-GstLoopbackTeardownError
