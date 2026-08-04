# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# LiteRT-LM v0.14.0 OSS-export bridge — DOT-SOURCED by build-litert-lm-from-source.ps1
# (it needs the caller's imported modules, e.g. Invoke-InlineRegexPatch).
#
# Google shipped the v0.14.0 tag with a CMake layer that was never buildable
# anywhere: it references the deleted constrained_decoding component, pins a
# LiteRT external from BEFORE the support/ tree its own shim headers include,
# and compiles none of the new logits_processor/support subsystems. Every
# function here is CONDITION-GATED on its specific breakage signature, so a
# future tag with a fixed export takes upstream's files untouched and this
# whole file self-retires — delete it (and its three call sites + the
# Dockerfile COPY) the day upstream's CMake catches up.
#
# ORDERING CONTRACT (enforced by the call sites in the main script):
#   1. Invoke-LiteRtLmExportStubs   — post-clone, before anything reads the components CMake
#   2. Invoke-LiteRtLmSupportGraft  — post-clone; writes $SourceDir\support + re-homed .cc
#      files that step 3's Test-Path gates and the staging globs depend on
#   3. Add-LiteRtLmV014OrphanSources — Phase 5, AFTER the cpu_affinity/orphans
#      Edit-SourceFile injection wrote the base source list it retargets/extends
# The prebuilt Gemma constraint-provider DLL staging stays in the main script's
# Phase 8 (it is part of exe staging, not of the source bridge).

function Invoke-LiteRtLmExportStubs {
    param([Parameter(Mandatory)][string]$SourceDir)
    # [LiteRTLM-winfix export-stubs] v0.14.0's OSS export ships a stale CMake layer:
    # runtime/components/CMakeLists.txt still add_subdirectory()s + facade-links
    # constrained_decoding (feature REMOVED upstream after 0.13.1 -- main renamed it
    # logits_processor; no sources exist at the tag, Bazel can't build it either) and
    # preprocessor (slimmed to header-only: 4 .h + BUILD, its CMakeLists.txt was never
    # exported). Configure hard-fails on both. Since the referenced code does not exist
    # at the tag, empty INTERFACE stubs are semantically exact -- nothing is stripped.
    $componentsDir  = Join-Path $SourceDir 'runtime\components'
    $componentsCml  = Join-Path $componentsDir 'CMakeLists.txt'
    $cdStubDir      = Join-Path $componentsDir 'constrained_decoding'
    if ((Test-Path $componentsCml) -and
        (Select-String -LiteralPath $componentsCml -Pattern 'add_subdirectory\(constrained_decoding\)' -Quiet) -and
        -not (Test-Path (Join-Path $cdStubDir 'CMakeLists.txt'))) {
        New-Item -Path $cdStubDir -ItemType Directory -Force | Out-Null
        # Target/alias names mirror v0.13.1's real CMakeLists so ANY stale reference
        # (facade or per-target) resolves. Single-quoted here-string: ${...} stays CMake's.
        $cdStub = @'
# [Kataglyphis export-stub] constrained_decoding was removed from the OSS export
# after v0.13.1 (renamed logits_processor on main) but this tag's CMake still
# references its targets. Empty INTERFACE stubs satisfy the stale links; the
# feature's sources do not exist at this tag, so nothing real is replaced.
foreach(_cd_name
    bitmap constraint constraint_provider constraint_provider_config
    constraint_config fst_constraint constrained_decoder
    constraint_provider_factory external_constraint_provider fake_constraint
    llg_constraint llg_constraint_provider llguidance_schema_utils
    gemma_model_constraint_provider libs)
  add_library(runtime_components_constrained_decoding_${_cd_name} INTERFACE)
endforeach()
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding ALIAS runtime_components_constrained_decoding_libs)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::Bitmap ALIAS runtime_components_constrained_decoding_bitmap)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::Constraint ALIAS runtime_components_constrained_decoding_constraint)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::ConstraintProvider ALIAS runtime_components_constrained_decoding_constraint_provider)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::ConstraintProviderConfig ALIAS runtime_components_constrained_decoding_constraint_provider_config)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::ConstraintConfig ALIAS runtime_components_constrained_decoding_constraint_config)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::FstConstraint ALIAS runtime_components_constrained_decoding_fst_constraint)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::Decoder ALIAS runtime_components_constrained_decoding_constrained_decoder)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::Factory ALIAS runtime_components_constrained_decoding_constraint_provider_factory)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::ExternalProvider ALIAS runtime_components_constrained_decoding_external_constraint_provider)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::FakeConstraint ALIAS runtime_components_constrained_decoding_fake_constraint)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::LlgConstraint ALIAS runtime_components_constrained_decoding_llg_constraint)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::LlgConstraintProvider ALIAS runtime_components_constrained_decoding_llg_constraint_provider)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::LlguidanceSchemaUtils ALIAS runtime_components_constrained_decoding_llguidance_schema_utils)
add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::GemmaModelConstraintProvider ALIAS runtime_components_constrained_decoding_gemma_model_constraint_provider)
'@
        [System.IO.File]::WriteAllText((Join-Path $cdStubDir 'CMakeLists.txt'), $cdStub + "`n")
        Write-Host '[LiteRTLM-winfix export-stubs] wrote constrained_decoding INTERFACE stub CMakeLists (feature absent from this export)'
    }
    $ppDir = Join-Path $componentsDir 'preprocessor'
    if ((Test-Path $ppDir) -and -not (Test-Path (Join-Path $ppDir 'CMakeLists.txt'))) {
        # Header-only at this tag (the 0.13.1 .cc files are gone from the export), so
        # INTERFACE targets carrying the include paths are the correct translation of
        # what remains. stb_lib guard: the top-level CMake FetchContents it for the
        # stb_image_preprocessor.h include; link it through when the target exists.
        $ppStub = @'
# [Kataglyphis export-stub] preprocessor is header-only in this export and its
# CMakeLists.txt was not exported; this replacement defines the v0.13.1 target
# names as INTERFACE libraries carrying the include paths the headers need.
foreach(_pp_name
    audio_preprocessor audio_preprocessor_miniaudio by_pass_audio_preprocessor
    by_pass_image_preprocessor image_preprocessor mel_filterbank
    signal_vector_util stb_image_preprocessor libs)
  add_library(runtime_components_preprocessor_${_pp_name} INTERFACE)
  if(DEFINED LITERTLM_INCLUDE_PATHS)
    target_include_directories(runtime_components_preprocessor_${_pp_name} INTERFACE ${LITERTLM_INCLUDE_PATHS})
  endif()
  if(DEFINED GENERATED_SRC_DIR)
    target_include_directories(runtime_components_preprocessor_${_pp_name} INTERFACE ${GENERATED_SRC_DIR})
  endif()
endforeach()
if(TARGET stb_lib)
  target_link_libraries(runtime_components_preprocessor_stb_image_preprocessor INTERFACE stb_lib)
endif()
add_library(LiteRTLM::Runtime::Components::Preprocessor ALIAS runtime_components_preprocessor_libs)
add_library(LiteRTLM::Runtime::Components::Preprocessor::Audio ALIAS runtime_components_preprocessor_audio_preprocessor)
add_library(LiteRTLM::Runtime::Components::Preprocessor::AudioMiniAudio ALIAS runtime_components_preprocessor_audio_preprocessor_miniaudio)
add_library(LiteRTLM::Runtime::Components::Preprocessor::AudioBypass ALIAS runtime_components_preprocessor_by_pass_audio_preprocessor)
add_library(LiteRTLM::Runtime::Components::Preprocessor::ImageBypass ALIAS runtime_components_preprocessor_by_pass_image_preprocessor)
add_library(LiteRTLM::Runtime::Components::Preprocessor::Image ALIAS runtime_components_preprocessor_image_preprocessor)
add_library(LiteRTLM::Runtime::Components::Preprocessor::MelFilterBank ALIAS runtime_components_preprocessor_mel_filterbank)
add_library(LiteRTLM::Runtime::Components::Preprocessor::SignalVectorUtil ALIAS runtime_components_preprocessor_signal_vector_util)
add_library(LiteRTLM::Runtime::Components::Preprocessor::StbImage ALIAS runtime_components_preprocessor_stb_image_preprocessor)
'@
        [System.IO.File]::WriteAllText((Join-Path $ppDir 'CMakeLists.txt'), $ppStub + "`n")
        Write-Host '[LiteRTLM-winfix export-stubs] wrote preprocessor INTERFACE stub CMakeLists (header-only in this export)'
    }
}

function Invoke-LiteRtLmSupportGraft {
    param([Parameter(Mandatory)][string]$SourceDir)
    # [LiteRTLM-winfix support-graft] v0.14.0 moved tokenizer/util/preprocessor impls
    # upstream into the LiteRT repo's top-level support/ tree (litert::support; the
    # runtime headers are copybara shims: `#include "support/util/..." // from @litert`).
    # But litert-lm's CMake pins litert_external at a 2026-03 commit that PREDATES
    # support/, and its source-staging globs (c/, runtime/, schema/) never copy a
    # support/ dir into GENERATED_SRC_DIR -- so every shim include 404s and the two
    # tokenizer targets have no sources. Bridge all of it from the LiteRT version this
    # container already ships (LITERT_VERSION). Gated on the shim signature.
    $mmShim = Join-Path $SourceDir 'runtime\util\memory_mapped_file.h'
    if (-not ((Test-Path $mmShim) -and
        (Select-String -LiteralPath $mmShim -Pattern '#include "support/' -Quiet) -and
        -not (Test-Path (Join-Path $SourceDir 'support\util\memory_mapped_file.h')))) {
        return
    }
    $litertRef = if ($env:LITERT_VERSION) { $env:LITERT_VERSION } else { 'v2.1.6' }
    $supportClone = 'C:\temp\litert-support-src'
    if (Test-Path $supportClone) { Remove-Item $supportClone -Recurse -Force }
    Write-Host "[LiteRTLM-winfix support-graft] sparse-cloning LiteRT $litertRef support/ tree..."
    # Canonical stderr-shield (git writes progress to stderr).
    [void](Invoke-ShieldedNative -Label "LiteRT $litertRef sparse clone" -CommandLine "git clone --depth 1 --branch $litertRef --filter=blob:none --sparse https://github.com/google-ai-edge/LiteRT.git `"$supportClone`"")
    [void](Invoke-ShieldedNative -Label 'LiteRT sparse-checkout support' -CommandLine "cd /d `"$supportClone`" && git sparse-checkout set support")
    if (-not (Test-Path "$supportClone\support\util\memory_mapped_file.h")) {
        throw "[LiteRTLM-winfix support-graft] LiteRT $litertRef sparse clone produced no support/util -- cannot satisfy litert-lm's support/ shim includes"
    }
    # Graft sources+headers only (tests/testdata/BUILD are dead weight in the staging globs).
    $dstSupport = Join-Path $SourceDir 'support'
    $grafted = 0
    Get-ChildItem "$supportClone\support" -Recurse -File -Include '*.cc', '*.h' |
        Where-Object { $_.Name -notmatch '_test\.cc$' -and $_.FullName -notmatch '\\testdata\\' } |
        ForEach-Object {
            $rel = $_.FullName.Substring("$supportClone\support\".Length)
            $dst = Join-Path $dstSupport $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $_.FullName $dst -Force
            $grafted++
        }
    Remove-Item $supportClone -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[LiteRTLM-winfix support-graft] grafted $grafted support/ file(s) from LiteRT $litertRef"
    # Re-home impls whose CMake targets still list the pre-move paths.
    $relocations = @(
        @{ From = 'support\util\memory_mapped_file_win.cc';      To = 'runtime\util\memory_mapped_file_win.cc' },
        @{ From = 'support\util\memory_mapped_file_posix.cc';    To = 'runtime\util\memory_mapped_file_posix.cc' },
        @{ From = 'support\tokenizer\huggingface_tokenizer.cc';  To = 'runtime\components\huggingface_tokenizer.cc' },
        @{ From = 'support\tokenizer\sentencepiece_tokenizer.cc'; To = 'runtime\components\sentencepiece_tokenizer.cc' }
    )
    foreach ($r in $relocations) {
        $from = Join-Path $SourceDir $r.From; $to = Join-Path $SourceDir $r.To
        if ((Test-Path $from) -and -not (Test-Path $to)) {
            Copy-Item $from $to -Force
            Write-Host "[LiteRTLM-winfix support-graft] re-homed $($r.From) -> $($r.To)"
        }
    }
    # Stage support/** into GENERATED_SRC_DIR via the same glob pipeline as runtime/**.
    # Both modules carry identical glob blocks; patch whichever exists.
    foreach ($modRel in @('cmake\modules\generators.cmake', 'cmake\modules\setup_generated_src_files.cmake')) {
        $modPath = Join-Path $SourceDir $modRel
        if (-not (Test-Path $modPath)) { continue }
        $modText = [System.IO.File]::ReadAllText($modPath)
        if ($modText -match 'SUPPORT_SRC_FILES') { continue }  # idempotent
        $oldSrcLine = 'list(APPEND ALL_SOURCE_FILES ${C_SRC_FILES} ${RUNTIME_SRC_FILES} ${SCHEMA_SRC_FILES})'
        $oldHdrLine = 'list(APPEND ALL_HEADER_FILES ${C_HDR_FILES} ${RUNTIME_HDR_FILES} ${SCHEMA_HDR_FILES})'
        if (-not $modText.Contains($oldSrcLine)) {
            Write-Warning "[LiteRTLM-winfix support-graft] $modRel glob anchor not found -- support/ staging NOT wired (build will fail on support/ includes)"
            continue
        }
        # PROJECT_ROOT-anchored like the module's own runtime/ globs -- a bare
        # "support/*.cc" resolves against cmake/packages/litert_lm and matches
        # NOTHING, silently (cost one container run to learn). All single-quoted:
        # ${...} here is CMake's, not PowerShell's.
        $newSrcLine = 'file(GLOB_RECURSE SUPPORT_SRC_FILES "${LITERTLM_PROJECT_ROOT}/support/*.cc")' + "`n" +
                      'file(GLOB_RECURSE SUPPORT_HDR_FILES "${LITERTLM_PROJECT_ROOT}/support/*.h")' + "`n" +
                      'list(APPEND ALL_SOURCE_FILES ${C_SRC_FILES} ${RUNTIME_SRC_FILES} ${SCHEMA_SRC_FILES} ${SUPPORT_SRC_FILES})'
        $modText = $modText.Replace($oldSrcLine, $newSrcLine)
        $modText = $modText.Replace($oldHdrLine, 'list(APPEND ALL_HEADER_FILES ${C_HDR_FILES} ${RUNTIME_HDR_FILES} ${SCHEMA_HDR_FILES} ${SUPPORT_HDR_FILES})')
        [System.IO.File]::WriteAllText($modPath, $modText)
        Write-Host "[LiteRTLM-winfix support-graft] wired support/ globs into $modRel"
    }
    # litert::Model::CreateFromFd(fd, offset, size) postdates the litert_external
    # pin (2026-03) -- the one caller is the NEW file-backed loading fast path, and
    # upstream's GetTFLiteModel treats kUnimplemented from it as "fall back to
    # buffer-backed loading" (the pre-0.14 path every prior release used). So stub
    # the helper body to return kUnimplemented instead of forward-porting the API.
    # Revisit when upstream's CMake bumps its litert pin past the CreateFromFd add.
    [void](Invoke-InlineRegexPatch -Path (Join-Path $SourceDir 'runtime\components\model_resources_litert_lm.cc') `
            -Pattern 'LITERT_ASSIGN_OR_RETURN\(auto dup_file,[\s\S]*?return model;' `
            -Replacement ('return absl::UnimplementedError(' + "`n" +
                '      "file-backed model loading disabled: litert_external pin predates "' + "`n" +
                '      "litert::Model::CreateFromFd; buffer-backed fallback engages");') `
            -Guard 'CreateFromFd' `
            -Description 'model_resources_litert_lm.cc: CreateFromFd fast path -> kUnimplemented (buffer-backed fallback)')
}

function Add-LiteRtLmV014OrphanSources {
    # Takes the engine CMakeLists TEXT (after the base orphan injection wrote the
    # source list this retargets/extends) and returns the bridged text. The caller
    # owns the read/compare/write cycle.
    param(
        [Parameter(Mandatory)][string]$EngineCmakeText,
        [Parameter(Mandatory)][string]$SourceDir
    )
    $engineTxt = $EngineCmakeText
    # v0.14.0 relocated two of the injected orphans; retarget the list entries when the
    # new locations exist (0.13.1 keeps the old paths -- both gates are Test-Path on the
    # NEW home, so this self-selects per version). The add_litertlm_library redirect
    # resolves ../../support/... to GENERATED_SRC_DIR/support/... (the grafted tree).
    if (Test-Path (Join-Path $SourceDir 'support\preprocessor\image_preprocessor_utils.cc')) {
        $engineTxt = $engineTxt.Replace('../components/preprocessor/image_preprocessor_utils.cc',
                                        '../../support/preprocessor/image_preprocessor_utils.cc')
    }
    if (Test-Path (Join-Path $SourceDir 'runtime\components\logits_processor\constrained_decoding\llg_tool_call_utils.cc')) {
        $engineTxt = $engineTxt.Replace('../components/constrained_decoding/llg_tool_call_utils.cc',
                                        '../components/logits_processor/constrained_decoding/llg_tool_call_utils.cc')
    }
    # v0.14.0's NEW subsystems compile nowhere: components/CMakeLists.txt never
    # add_subdirectory()s logits_processor (the renamed constrained decoding), and the
    # grafted support/ impls have no targets either -- link died with undefined
    # MelFilterbank::Initialize / CreateConstraintProvider / ConstrainedDecoder vtable /
    # InputText::GetRawTextString. Same cure as the other orphans: compile them into the
    # engine lib. Gated on the logits_processor dir (absent on 0.13.1).
    # The miniaudio/stb preprocessors ARE demanded at link (AudioPreprocessorMiniAudio::
    # Create, the ImagePreprocessor factory) and their externals are ALREADY FetchContent'd
    # by upstream's top CMakeLists (kissfft_lib/miniaudio_lib/stb -- their CMake migration
    # fetched the new deps but never wired the new sources); the dep block appended below
    # links them through. LiteRtLmGemmaModelConstraintProvider_* are dllimports satisfied
    # by upstream's OWN prebuilt import lib (prebuilt/windows_x86_64/), staged in Phase 8.
    if ((Test-Path (Join-Path $SourceDir 'runtime\components\logits_processor')) -and
        ($engineTxt -notmatch 'logits_processor/repetition_penalty_processor')) {
        $newOrphans = @(
            '../components/logits_processor/repetition_penalty_processor.cc'
            '../components/logits_processor/constrained_decoding/constrained_decoder.cc'
            '../components/logits_processor/constrained_decoding/constraint_provider_factory.cc'
            '../components/logits_processor/constrained_decoding/external_constraint_provider.cc'
            '../components/logits_processor/constrained_decoding/fake_constraint.cc'
            '../components/logits_processor/constrained_decoding/llguidance_schema_utils.cc'
            '../components/logits_processor/constrained_decoding/llg_constraint.cc'
            '../components/logits_processor/constrained_decoding/llg_constraint_provider.cc'
            '../components/logits_processor/constrained_decoding/llg_fc_tool_calls.cc'
            '../components/logits_processor/constrained_decoding/llg_python_tool_calls.cc'
            '../../support/util/io_types.cc'
            '../../support/preprocessor/mel_filterbank.cc'
            '../../support/preprocessor/audio_preprocessor_miniaudio.cc'
            '../../support/preprocessor/stb_image_preprocessor.cc'
            '../conversation/model_data_processor/multimodal_processor_helper.cc'
        )
        $engineTxt = $engineTxt.Replace('../util/log_tensor_buffer.cc',
            "../util/log_tensor_buffer.cc`n  " + ($newOrphans -join "`n  ") + "  # [LiteRTLM-winfix v0.14 orphans]")
        Write-Host "[LiteRTLM-winfix orphans] added $($newOrphans.Count) v0.14 subsystem sources (logits_processor + support impls) to the engine lib"
        if ($engineTxt -notmatch 'LiteRTLM-winfix v0\.14-deps') {
            $engineTxt += @'

# [LiteRTLM-winfix v0.14-deps] externals for the injected support/ preprocessors:
# upstream's fetch_content.cmake already provides these targets/dirs; wire them to
# the engine lib that now compiles audio_preprocessor_miniaudio.cc + stb_image_
# preprocessor.cc. The Gemma model constraint provider is upstream's PREBUILT
# component (only shipped as dll+lib) -- link its import lib; the dll is staged
# next to litert_lm_main.exe by the build script.
foreach(_wf_dep miniaudio_lib kissfft_lib miniaudio kissfft stb_lib)
  if(TARGET ${_wf_dep})
    target_link_libraries(runtime_engine_litert_lm_lib PUBLIC ${_wf_dep})
  endif()
endforeach()
foreach(_wf_inc "${MINIAUDIO_SRC_DIR}" "${KISSFFT_SRC_DIR}" "${THIRD_PARTY_DIR}/stb" "${THIRD_PARTY_DIR}/miniaudio" "${THIRD_PARTY_DIR}/kissfft")
  if(_wf_inc AND EXISTS "${_wf_inc}")
    target_include_directories(runtime_engine_litert_lm_lib PRIVATE "${_wf_inc}")
  endif()
endforeach()
if(EXISTS "${LITERTLM_PROJECT_ROOT}/prebuilt/windows_x86_64/libGemmaModelConstraintProvider.lib")
  target_link_libraries(runtime_engine_litert_lm_lib PUBLIC "${LITERTLM_PROJECT_ROOT}/prebuilt/windows_x86_64/libGemmaModelConstraintProvider.lib")
endif()
'@
            Write-Host '[LiteRTLM-winfix orphans] appended v0.14-deps block (miniaudio/kissfft/stb wiring + prebuilt Gemma constraint provider import lib)'
        }
    }
    return $engineTxt
}
