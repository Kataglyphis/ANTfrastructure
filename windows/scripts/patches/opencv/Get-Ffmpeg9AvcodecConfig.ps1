#requires -Version 7.0
<#
.SYNOPSIS
    Makes OpenCV 5.0.0's videoio compile against FFmpeg 9, which removed AVCodec pix_fmts and supported_framerates.
.DESCRIPTION
    An in-script edit, not a .patch: matching the accessor survives point releases that move the context.
    Version-guarded, so FFmpeg below avcodec 61.13 keeps using the old fields.
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

# The shims keep the classic terminators, so every existing caller loop stays untouched.
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
    # The shim's own delimiter, never the helper name: the accessor rewrite already put that name in the file.
    if ($text -match [regex]::Escape($shimMarker)) {
        Write-Host "  $(Split-Path $Path -Leaf): shim already present, skipping insert"
        return
    }
    # After the FFmpeg extern "C" block: unconditional, past avcodec.h, and above every use (the last #include is in a false #ifdef).
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
    # Step past the closing brace's `#ifdef __cplusplus` guard so the shim sits at true top level.
    $tail = $text.Substring($at, [Math]::Min(200, $text.Length - $at))
    $endifMatch = [regex]::Match($tail, '^\s*(\r?\n)?[ \t]*#[ \t]*endif[^\r\n]*')
    if ($endifMatch.Success) { $at += $endifMatch.Length }
    $updated = $text.Substring(0, $at) + "`n" + $Shim + $text.Substring($at)
    Set-Content -LiteralPath $Path -Value $updated -NoNewline -Encoding ascii
    Write-Host "  $(Split-Path $Path -Leaf): inserted shim after the FFmpeg extern-C block (offset $at)"

    # A shim after the first call site fails the compile 20 minutes in; check it here instead.
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

# Accessors first: the reverse order rewrites the shim's fallback into infinite recursion. A patched file is a no-op.
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

# A missed site fails the compile much later with no pointer back here; the shims' own fallbacks are cut out first.
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
