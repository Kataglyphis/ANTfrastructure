; The family's per-machine NSIS setup; Invoke-NsisPackage passes every KG_* define. See docs/adopting-in-a-new-project.md#nsis-setups
Unicode true
ManifestDPIAware true
SetCompressor /FINAL zlib
RequestExecutionLevel admin

!include "MUI2.nsh"
!include "${__FILEDIR__}\kataglyphis-common.nsh"

!insertmacro KG_REQUIRE KG_PRODUCT_NAME
!insertmacro KG_REQUIRE KG_VERSION
!insertmacro KG_REQUIRE KG_PUBLISHER
!insertmacro KG_REQUIRE KG_ARCH
!insertmacro KG_REQUIRE KG_MAIN_EXE
!insertmacro KG_REQUIRE KG_UNINSTALL_KEY
!insertmacro KG_REQUIRE KG_LICENSE_FILE
!insertmacro KG_REQUIRE KG_FILE_LIST
!insertmacro KG_REQUIRE KG_OTHER_ARCH_SETUP
!insertmacro KG_REQUIRE KG_OUTFILE
!ifndef KG_SHORTCUT_ARGS
  !define KG_SHORTCUT_ARGS ""
!endif

!include "${KG_FILE_LIST}"

Name "${KG_PRODUCT_NAME}"
OutFile "${KG_OUTFILE}"

; The PFX password stays in the environment the signing script inherits, never on this command line.
!ifdef KG_SIGN_PFX
  !finalize '"${KG_SIGN_PWSH}" -NoProfile -NonInteractive -File "${__FILEDIR__}\Invoke-NsisSign.ps1" -Path "%1" -PfxPath "${KG_SIGN_PFX}" -LogDir "${KG_SIGN_LOGDIR}"' = 0
  !uninstfinalize '"${KG_SIGN_PWSH}" -NoProfile -NonInteractive -File "${__FILEDIR__}\Invoke-NsisSign.ps1" -Path "%1" -PfxPath "${KG_SIGN_PFX}" -LogDir "${KG_SIGN_LOGDIR}"' = 0
!endif
InstallDir "$PROGRAMFILES64\${KG_PRODUCT_NAME}"
VIProductVersion "${KG_VERSION}"
VIAddVersionKey "ProductName" "${KG_PRODUCT_NAME}"
VIAddVersionKey "CompanyName" "${KG_PUBLISHER}"
VIAddVersionKey "FileVersion" "${KG_VERSION}"
VIAddVersionKey "ProductVersion" "${KG_VERSION}"
VIAddVersionKey "FileDescription" "${KG_PRODUCT_NAME} Setup"
VIAddVersionKey "LegalCopyright" "Copyright ${KG_PUBLISHER}"

!ifdef KG_ICON
  !define MUI_ICON "${KG_ICON}"
  !define MUI_UNICON "${KG_ICON}"
!endif
!insertmacro MUI_PAGE_LICENSE "${KG_LICENSE_FILE}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  !insertmacro KG_INIT
FunctionEnd

Function un.onInit
  !insertmacro KG_UNINIT
FunctionEnd

Section "Install"
  !insertmacro KG_REMOVE_PREVIOUS
  !insertmacro KG_INSTALL_FILES
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\${KG_PRODUCT_NAME}.lnk" "$INSTDIR\${KG_MAIN_EXE}" "${KG_SHORTCUT_ARGS}"
  !insertmacro KG_WRITE_UNINSTALL_KEY
SectionEnd

; Only the files this setup installed are removed, never a recursive delete of a user-chosen directory.
Section "Uninstall"
  Delete "$SMPROGRAMS\${KG_PRODUCT_NAME}.lnk"
  !insertmacro KG_UNINSTALL_FILES
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "${KG_UNINSTALL_ROOT}"
SectionEnd
