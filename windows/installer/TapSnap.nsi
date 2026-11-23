Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!ifndef PAYLOAD
    !error "Define PAYLOAD as the self-contained dotnet publish directory."
!endif
!ifndef OUTPUT
    !error "Define OUTPUT as the setup EXE path."
!endif
!ifndef ARCH
    !error "Define ARCH as x64 or arm64."
!endif
!ifndef VERSION
    !error "Define VERSION as the installer version."
!endif
!ifndef FILE_VERSION
    !error "Define FILE_VERSION as four numeric version components."
!endif

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\TapSnap"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"

Name "TapSnap"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\TapSnap"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
BrandingText "TapSnap ${VERSION} · ${ARCH}"
VIProductVersion "${FILE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "TapSnap"
VIAddVersionKey /LANG=1033 "FileDescription" "TapSnap ${ARCH} Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${FILE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "TapSnap contributors"

!define MUI_ICON "../TapSnap.Windows/TapSnap.ico"
!define MUI_UNICON "../TapSnap.Windows/TapSnap.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\app\TapSnap.exe"
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE VerifyInstallDirectory
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

LangString CloseApp ${LANG_SIMPCHINESE} "请先从通知区域退出 TapSnap，再重试。"
LangString CloseApp ${LANG_ENGLISH} "Quit TapSnap from the notification area, then try again."
LangString WrongArch ${LANG_SIMPCHINESE} "此安装包适用于 ${ARCH} Windows，请选择与电脑架构对应的版本。"
LangString WrongArch ${LANG_ENGLISH} "This installer is for ${ARCH} Windows. Choose the installer for your PC architecture."
LangString DirectoryInUse ${LANG_SIMPCHINESE} "此目录已有程序文件。请选择 TapSnap 的现有目录，或选择其他目录。"
LangString DirectoryInUse ${LANG_ENGLISH} "This folder already contains program files. Select the existing TapSnap folder or choose another folder."
LangString ChangeDirectory ${LANG_SIMPCHINESE} "TapSnap 当前安装在 $0。请先从 Windows 设置卸载当前版本，再选择新的安装目录。"
LangString ChangeDirectory ${LANG_ENGLISH} "TapSnap is installed at $0. To change folders, uninstall the current version in Windows Settings first."

!macro WaitForTapSnap
    ${Do}
        System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\TapSnap.Windows") p.r0'
        ${If} $0 == 0
            ${ExitDo}
        ${EndIf}
        System::Call 'kernel32::CloseHandle(p r0)'
        MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "$(CloseApp)" /SD IDCANCEL IDRETRY +2
        Abort
    ${Loop}
!macroend

Function .onInit
    SetShellVarContext current
    !if "${ARCH}" == "arm64"
        ${IfNot} ${IsNativeARM64}
            MessageBox MB_OK|MB_ICONSTOP "$(WrongArch)" /SD IDOK
            Abort
        ${EndIf}
    !else if "${ARCH}" == "x64"
        ${IfNot} ${IsNativeAMD64}
            MessageBox MB_OK|MB_ICONSTOP "$(WrongArch)" /SD IDOK
            Abort
        ${EndIf}
    !else
        !error "ARCH must be x64 or arm64."
    !endif
FunctionEnd

Function VerifyInstallDirectory
    ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "InstallLocation"
    ${If} $0 == $INSTDIR
        Return
    ${EndIf}
    ${If} $0 != ""
    ${AndIf} ${FileExists} "$0\Uninstall.exe"
        MessageBox MB_OK|MB_ICONEXCLAMATION "$(ChangeDirectory)" /SD IDOK
        Abort
    ${EndIf}
    ${If} ${FileExists} "$INSTDIR\app"
    ${OrIf} ${FileExists} "$INSTDIR\Uninstall.exe"
        MessageBox MB_OK|MB_ICONEXCLAMATION "$(DirectoryInUse)" /SD IDOK
        Abort
    ${EndIf}
FunctionEnd

Section "TapSnap"
    Call VerifyInstallDirectory
    !insertmacro WaitForTapSnap
    SetOutPath "$INSTDIR\app"
    File /r "${PAYLOAD}\*"
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    CreateShortcut "$SMPROGRAMS\TapSnap.lnk" "$INSTDIR\app\TapSnap.exe"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "TapSnap"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "TapSnap"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\app\TapSnap.exe"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
    SetShellVarContext current
    !insertmacro WaitForTapSnap
    ReadRegStr $0 HKCU "${RUN_KEY}" "TapSnap"
    ${If} $0 == '"$INSTDIR\app\TapSnap.exe"'
        DeleteRegValue HKCU "${RUN_KEY}" "TapSnap"
    ${EndIf}
    Delete "$SMPROGRAMS\TapSnap.lnk"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    RMDir /r "$INSTDIR\app"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
