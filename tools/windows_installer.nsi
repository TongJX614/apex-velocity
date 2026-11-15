; APEX VELOCITY · 极速巅峰 — Windows 安装包 (NSIS 3.10, Unicode)
Unicode true
ManifestDPIAware true

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define PRODUCT_NAME "APEX VELOCITY · 极速巅峰"
!define PRODUCT_NAME_SHORT "APEX VELOCITY"
!define PRODUCT_VERSION "0.54.0"
!define PRODUCT_EXE "APEX_VELOCITY.exe"
!define PRODUCT_PUBLISHER "APEX VELOCITY"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\APEXVELOCITY"
!define BUILD_DIR "/Users/tong/Desktop/极速巅峰/build/windows"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "/Users/tong/Desktop/极速巅峰/build/release/APEX_VELOCITY_${PRODUCT_VERSION}_Windows_x64_Setup.exe"
InstallDir "$PROGRAMFILES64\APEX VELOCITY"
InstallDirRegKey HKLM "Software\APEXVELOCITY" "InstallDir"
RequestExecutionLevel admin
SetCompressor lzma
SetCompressorDictSize 32

VIProductVersion "0.54.0.0"
VIAddVersionKey /LANG=2052 "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=2052 "FileDescription" "${PRODUCT_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "0.54.0.0"
VIAddVersionKey /LANG=2052 "LegalCopyright" ""

!define MUI_ICON "/Users/tong/Desktop/极速巅峰/assets/branding/apex_icon.ico"
!define MUI_UNICON "/Users/tong/Desktop/极速巅峰/assets/branding/apex_icon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动 ${PRODUCT_NAME_SHORT}"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\运行说明.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "查看运行说明"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

LangString DESC_Core ${LANG_SIMPCHINESE} "游戏本体（可执行文件与全部赛道、车辆资源）"
LangString DESC_Core ${LANG_ENGLISH} "Game files (executable and all tracks/vehicles)"
LangString DESC_Shortcut ${LANG_SIMPCHINESE} "创建桌面快捷方式"
LangString DESC_Shortcut ${LANG_ENGLISH} "Create desktop shortcut"

Section "游戏本体 (必装)" SecCore
	SectionIn RO
	SetOutPath "$INSTDIR"
	SetOverwrite on
	File "${BUILD_DIR}/APEX_VELOCITY.exe"
	File "${BUILD_DIR}/split/APEX_VELOCITY.pck"
	File "${BUILD_DIR}/split/APEX_VELOCITY_data.pck"
	File "${BUILD_DIR}/运行说明.txt"
	WriteRegStr HKLM "Software\APEXVELOCITY" "InstallDir" "$INSTDIR"
	WriteUninstaller "$INSTDIR\Uninstall.exe"
	CreateDirectory "$SMPROGRAMS\APEX VELOCITY"
	CreateShortcut "$SMPROGRAMS\APEX VELOCITY\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}" "" "$INSTDIR\${PRODUCT_EXE}" 0
	CreateShortcut "$SMPROGRAMS\APEX VELOCITY\卸载 ${PRODUCT_NAME_SHORT}.lnk" "$INSTDIR\Uninstall.exe"
	WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
	WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
	WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
	WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${PRODUCT_EXE}"
	WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
	WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
	WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
	WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
	${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
	IntFmt $0 "0x%08X" $0
	WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

Section "桌面快捷方式" SecShortcut
	CreateShortcut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}" "" "$INSTDIR\${PRODUCT_EXE}" 0
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
	!insertmacro MUI_DESCRIPTION_TEXT ${SecCore} $(DESC_Core)
	!insertmacro MUI_DESCRIPTION_TEXT ${SecShortcut} $(DESC_Shortcut)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
	Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
	Delete "$SMPROGRAMS\APEX VELOCITY\${PRODUCT_NAME}.lnk"
	Delete "$SMPROGRAMS\APEX VELOCITY\卸载 ${PRODUCT_NAME_SHORT}.lnk"
	RMDir "$SMPROGRAMS\APEX VELOCITY"
	Delete "$INSTDIR\${PRODUCT_EXE}"
	Delete "$INSTDIR\APEX_VELOCITY.pck"
	Delete "$INSTDIR\APEX_VELOCITY_data.pck"
	Delete "$INSTDIR\运行说明.txt"
	Delete "$INSTDIR\Uninstall.exe"
	RMDir "$INSTDIR"
	DeleteRegKey HKLM "${UNINST_KEY}"
	DeleteRegKey HKLM "Software\APEXVELOCITY"
SectionEnd

Function .onInit
	SetShellVarContext all
	SetRegView 64
FunctionEnd

Function un.onInit
	SetShellVarContext all
	SetRegView 64
FunctionEnd