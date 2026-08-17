#requires -Version 7.0
<#
.SYNOPSIS
    Make OpenCV 5.0.0's videoio compile against FFmpeg 9 (avcodec 63).
    Backlog #94.

.DESCRIPTION
    FFmpeg deprecated the direct AVCodec fields `pix_fmts` and
    `supported_framerates` in 7.1 and REMOVED them by 9.0, in favour of

        avcodec_get_supported_config(avctx, codec, config, flags,
                                     &out_configs, &out_num_configs)

    OpenCV 5.0.0 predates the removal, so its videoio fails to build against the
    FFmpeg this chain ships:

        cap_ffmpeg_hw.hpp(760,761,762)     no member named 'pix_fmts'
        cap_ffmpeg_impl.hpp(2632,2633)     no member named 'supported_framerates'

    Applied as an in-script edit rather than a .patch file ON PURPOSE: a unified
    diff has to match upstream context byte for byte, and the same five sites
    move with every OpenCV point release. Matching the ACCESSOR (`c->pix_fmts`)
    instead of its surroundings survives that; the assertions below turn any
    upstream reshuffle into a loud failure instead of a silent no-op — the rule
    from backlog #56.

    Deliberately keeps the existing loops untouched. With the last argument of
    avcodec_get_supported_config() left NULL, the returned array is still
    terminated the old way (AV_PIX_FMT_NONE / a zero AVRational), so only the
    way the pointer is OBTAINED changes.

    Version-guarded: the shims fall back to the old fields below avcodec 61.13,
    so this does not trade one incompatibility for the reverse one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir
)

$ErrorActionPreference = 'Stop'

$videoioSrc = Join-Path $SourceDir 'modules\videoio\src'
$hwFile = Join-Path $videoioSrc 'cap_ffmpeg_hw.hpp'
$implFile = Join-Path $videoioSrc 'cap_ffmpeg_impl.hpp'

foreach ($f in $hwFile, $implFile) {
    if (-not (Test-Path $f)) {
        throw "ffmpeg9-avcodec-config: expected OpenCV source file missing: $f (wrong -SourceDir, or the videoio layout moved)"
    }
}

# Inserted after the LAST #include of the file: anchoring on an include keeps
# working when upstream reorders code, and both files include the FFmpeg headers
# before any use, so LIBAVCODEC_VERSION_INT is defined by then.
$shimHw = @'

// >>> OCV_FFMPEG9_SHIM BEGIN
// --- backlog #94: FFmpeg 9 removed AVCodec::pix_fmts (see the patch script) ---
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(61, 13, 100)
static inline const enum AVPixelFormat* ocv_codec_pix_fmts(const AVCodec* c)
{
    const enum AVPixelFormat* p = NULL;
    if (!c) return NULL;
    // out_num_configs = NULL keeps the classic AV_PIX_FMT_NONE terminator, so
    // every caller's `for (; p[i] != AV_PIX_FMT_NONE; ...)` loop still works.
    if (avcodec_get_supported_config(NULL, c, AV_CODEC_CONFIG_PIX_FORMAT, 0,
                                     (const void**)&p, NULL) < 0)
        return NULL;
    return p;
}
#else
static inline const enum AVPixelFormat* ocv_codec_pix_fmts(const AVCodec* c)
{
    return c ? c->pix_fmts : NULL;
}
#endif
// <<< OCV_FFMPEG9_SHIM END
'@

$shimImpl = @'

// >>> OCV_FFMPEG9_SHIM BEGIN
// --- backlog #94: FFmpeg 9 removed AVCodec::supported_framerates -------------
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(61, 13, 100)
static inline const AVRational* ocv_codec_frame_rates(const AVCodec* c)
{
    const AVRational* p = NULL;
    if (!c) return NULL;
    // Zero-AVRational terminated, matching the old `for(; p->den != 0; p++)`.
    if (avcodec_get_supported_config(NULL, c, AV_CODEC_CONFIG_FRAME_RATE, 0,
                                     (const void**)&p, NULL) < 0)
        return NULL;
    return p;
}
#else
static inline const AVRational* ocv_codec_frame_rates(const AVCodec* c)
{
    return c ? c->supported_framerates : NULL;
}
#endif
// <<< OCV_FFMPEG9_SHIM END
'@

$shimMarker = '// >>> OCV_FFMPEG9_SHIM BEGIN'

function Add-ShimAfterLastInclude {
    param([string]$Path, [string]$Shim)

    $text = Get-Content -LiteralPath $Path -Raw
    # Marker must be the SHIM's own delimiter, never the helper NAME: the
    # accessor rewrite runs first and puts `ocv_codec_pix_fmts(c)` into the file,
    # so a name-based check reports "already present" and silently skips the
    # insert — leaving calls to a function that was never defined. The dry run
    # caught exactly that.
    if ($text -match [regex]::Escape($shimMarker)) {
        Write-Host "  $(Split-Path $Path -Leaf): shim already present, skipping insert"
        return
    }
    # ANCHOR: after the `extern "C" { ... }` block that pulls in
    # <libavcodec/avcodec.h>. Two earlier anchors both failed for reasons worth
    # keeping:
    #
    #  * `(?m)^\s*#\s*include[^\r\n]*$` matched ZERO includes in a CRLF checkout
    #    (`[^\r\n]*` stops before `\r`; .NET's `$` only matches before `\n`),
    #    while matching all 20 in the same file with LF endings.
    #  * "after the LAST #include" then put the shim inside
    #    `#ifdef HAVE_VA_INTEL` / `hwcontext_drm.h` territory — a preprocessor
    #    branch that is FALSE in this build, so the helpers were compiled out and
    #    the call sites failed with "use of undeclared identifier".
    #
    # The end of the FFmpeg `extern "C"` block is unconditional, sits after
    # avcodec.h (so LIBAVCODEC_VERSION_INT is defined), and is above every use
    # site in both files.
    $externIdx = -1
    foreach ($m in [regex]::Matches($text, 'extern\s*"C"\s*\{')) {
        $window = $text.Substring($m.Index, [Math]::Min(4000, $text.Length - $m.Index))
        if ($window -match 'libavcodec/avcodec\.h') { $externIdx = $m.Index + $m.Length; break }
    }
    if ($externIdx -lt 0) {
        throw ("ffmpeg9-avcodec-config: no `extern `"C`" {` block including <libavcodec/avcodec.h> found in $Path - " +
            "cannot anchor the compatibility shim. Upstream restructured the includes; re-check backlog #94.")
    }
    # Walk to the matching closing brace of that extern "C" block.
    $depth = 1
    $at = -1
    for ($i = $externIdx; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { $at = $i + 1; break }
        }
    }
    if ($at -lt 0) {
        throw "ffmpeg9-avcodec-config: unbalanced `extern `"C`"` block in $Path - cannot anchor the compatibility shim"
    }
    # cap_ffmpeg_impl.hpp wraps the block as
    #     #ifdef __cplusplus
    #     extern "C" {
    #     #endif   ... includes ...   #ifdef __cplusplus
    #     }
    #     #endif
    # so the matching `}` is INSIDE `#ifdef __cplusplus`. Landing there compiles
    # (this is C++), but stepping past the trailing `#endif` puts the shim at
    # genuine top level in both files instead of relying on that.
    $tail = $text.Substring($at, [Math]::Min(200, $text.Length - $at))
    $endifMatch = [regex]::Match($tail, '^\s*(\r?\n)?[ \t]*#[ \t]*endif[^\r\n]*')
    if ($endifMatch.Success) { $at += $endifMatch.Length }
    $updated = $text.Substring(0, $at) + "`n" + $Shim + $text.Substring($at)
    Set-Content -LiteralPath $Path -Value $updated -NoNewline -Encoding ascii
    Write-Host "  $(Split-Path $Path -Leaf): inserted shim after the FFmpeg extern-C block (offset $at)"

    # The shim must precede every call site, or the compiler reports "use of
    # undeclared identifier" 20 minutes into the build. Check it here instead.
    $firstUse = [regex]::Match($updated, 'ocv_codec_(pix_fmts|frame_rates)\s*\(\s*(c|codec)\s*\)')
    $shimAt = $updated.IndexOf($shimMarker)
    if ($firstUse.Success -and $shimAt -ge 0 -and $firstUse.Index -lt $shimAt) {
        throw ("ffmpeg9-avcodec-config: in $Path the shim landed AFTER the first call site " +
            "(shim at $shimAt, first use at $($firstUse.Index)) - it would not be declared at the point of use.")
    }
}

function Set-AccessorRequired {
    param([string]$Path, [string]$Pattern, [string]$Replacement, [string]$What)

    $text = Get-Content -LiteralPath $Path -Raw
    $count = ([regex]::Matches($text, $Pattern)).Count
    if ($count -eq 0) {
        throw ("ffmpeg9-avcodec-config: found NO occurrence of $What in $Path. Upstream changed this code; " +
            "re-check the five sites listed in backlog #94 instead of shipping an unpatched videoio.")
    }
    $updated = [regex]::Replace($text, $Pattern, $Replacement)
    Set-Content -LiteralPath $Path -Value $updated -NoNewline -Encoding ascii
    Write-Host "  $(Split-Path $Path -Leaf): rewrote $count occurrence(s) of $What"
}

Write-Host 'Patching OpenCV videoio for FFmpeg 9 (backlog #94)...'

# ORDER MATTERS: rewrite the accessors FIRST, insert the shim SECOND. Doing it
# the other way round rewrites the shim's own pre-FFmpeg-9 fallback
# (`return c ? c->pix_fmts : NULL;`) into a call to itself — infinite recursion
# on any older FFmpeg, and it compiles cleanly. Caught by the dry run, not by
# review; keep the order and keep the dry run.
#
# IDEMPOTENT: the source tree can be re-patched (a resumed chain, a retried
# layer), so an already-patched file is a no-op, not an error. Only an
# UNPATCHED file that lacks the expected accessor is a real failure.
function Update-VideoioFile {
    param([string]$Path, [string]$Pattern, [string]$Replacement, [string]$What, [string]$Shim)

    if ((Get-Content -LiteralPath $Path -Raw) -match [regex]::Escape($shimMarker)) {
        Write-Host "  $(Split-Path $Path -Leaf): already patched, nothing to do"
        return
    }
    Set-AccessorRequired -Path $Path -Pattern $Pattern -Replacement $Replacement -What $What
    Add-ShimAfterLastInclude -Path $Path -Shim $Shim
}

Update-VideoioFile -Path $hwFile -Pattern '\bc->pix_fmts\b' -Replacement 'ocv_codec_pix_fmts(c)' `
    -What 'c->pix_fmts' -Shim $shimHw
Update-VideoioFile -Path $implFile -Pattern '\bcodec->supported_framerates\b' -Replacement 'ocv_codec_frame_rates(codec)' `
    -What 'codec->supported_framerates' -Shim $shimImpl

# Fail loudly if any direct field access survived anywhere in videoio: a missed
# site is a compile error later in a 20-minute build, and the message there
# ("no member named ...") does not point back here. The shim's own fallback
# branch legitimately uses the old fields, so cut those spans out first.
$leftovers = @()
foreach ($f in Get-ChildItem -Path $videoioSrc -Filter 'cap_ffmpeg*.hpp' -File) {
    $t = Get-Content -LiteralPath $f.FullName -Raw
    $t = [regex]::Replace($t, '(?s)// >>> OCV_FFMPEG9_SHIM BEGIN.*?// <<< OCV_FFMPEG9_SHIM END', '')
    foreach ($field in 'pix_fmts', 'supported_framerates') {
        foreach ($m in [regex]::Matches($t, "->\s*$field\b")) {
            $leftovers += "$($f.Name): ->$field"
        }
    }
}
if ($leftovers) {
    throw ("ffmpeg9-avcodec-config: direct AVCodec field access still present after patching: " +
        ($leftovers -join ', ') + ". These do not exist in FFmpeg 9 and will fail the compile. Backlog #94.")
}

Write-Host 'OpenCV videoio FFmpeg-9 patch applied and verified (no direct pix_fmts/supported_framerates access left).'
