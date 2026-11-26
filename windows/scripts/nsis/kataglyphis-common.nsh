; Shared setup logic for the family's NSIS setups; see docs/adopting-in-a-new-project.md#nsis-setups
!ifndef KATAGLYPHIS_COMMON_NSH
!define KATAGLYPHIS_COMMON_NSH

!include "LogicLib.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"

!macro KG_REQUIRE NAME
  !ifndef ${NAME}
    !error "makensis needs /D${NAME}=<value>; Invoke-NsisPackage passes every required define"
  !endif
!macroend

!define KG_UNINSTALL_ROOT "Software\Microsoft\Windows\CurrentVersion\Uninstall\${KG_UNINSTALL_KEY}"

; /SD keeps a silent run free of dialogs; exit code 2 tells a silent caller the setup refused.
!macro KG_REFUSE MSG
  MessageBox MB_ICONSTOP|MB_OK "${MSG}" /SD IDOK
  SetErrorLevel 2
  Quit
!macroend

!macro KG_ARCH_CHECK
  !if "${KG_ARCH}" == "x64"
    ${If} ${IsNativeARM64}
      !insertmacro KG_REFUSE "This setup is for x64 Windows. On ARM64, run ${KG_OTHER_ARCH_SETUP} instead."
    ${ElseIfNot} ${IsNativeAMD64}
      !insertmacro KG_REFUSE "This setup needs 64-bit x64 Windows."
    ${EndIf}
  !else if "${KG_ARCH}" == "arm64"
    ${IfNot} ${IsNativeARM64}
      !insertmacro KG_REFUSE "This setup is for ARM64 Windows. On x64, run ${KG_OTHER_ARCH_SETUP} instead."
    ${EndIf}
  !else
    !error "KG_ARCH must be x64 or arm64"
  !endif
!macroend

; An MSI install of the same product shares the files and Start-menu entry, so two installers must not stack.
!macro KG_MSI_GUARD
  !ifdef KG_MSI_UPGRADE_CODE
    System::Call 'msi::MsiEnumRelatedProductsW(w "${KG_MSI_UPGRADE_CODE}", i 0, i 0, w .r1) i .r0'
    ${If} $0 == 0
      !insertmacro KG_REFUSE "${KG_PRODUCT_NAME} is installed from its MSI package. Remove it under Settings > Apps first."
    ${EndIf}
  !endif
!macroend

!macro KG_INIT
  SetShellVarContext all
  SetRegView 64
  !insertmacro KG_ARCH_CHECK
  !insertmacro KG_MSI_GUARD
  ReadRegStr $0 HKLM "${KG_UNINSTALL_ROOT}" "InstallLocation"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
  ${EndIf}
!macroend

!macro KG_UNINIT
  SetShellVarContext all
  SetRegView 64
!macroend

; The key carries no version, so an upgrade finds the old install and runs its uninstaller in place first.
!macro KG_REMOVE_PREVIOUS
  ReadRegStr $R0 HKLM "${KG_UNINSTALL_ROOT}" "InstallLocation"
  ${If} $R0 != ""
  ${AndIf} ${FileExists} "$R0\Uninstall.exe"
    DetailPrint "Removing the installed version from $R0"
    ExecWait '"$R0\Uninstall.exe" /S _?=$R0' $R1
    ${If} $R1 != 0
      !insertmacro KG_REFUSE "The installed version in $R0 could not be removed (exit $R1)."
    ${EndIf}
    Delete "$R0\Uninstall.exe"
    RMDir "$R0"
  ${EndIf}
!macroend

!macro KG_WRITE_UNINSTALL_KEY
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "DisplayName" "${KG_PRODUCT_NAME}"
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "DisplayVersion" "${KG_VERSION}"
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "Publisher" "${KG_PUBLISHER}"
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "DisplayIcon" "$INSTDIR\${KG_MAIN_EXE}"
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${KG_UNINSTALL_ROOT}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${KG_UNINSTALL_ROOT}" "NoModify" 1
  WriteRegDWORD HKLM "${KG_UNINSTALL_ROOT}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${KG_UNINSTALL_ROOT}" "EstimatedSize" "$0"
!macroend

!endif
