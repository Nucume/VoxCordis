; Inno Setup script for VoxCordis.
; Copyright (C) 2026 Nucume
;
; CI calls: ISCC /DAppVersion=0.1.0 /DSourceDir=<release dir> /DOutputDir=<dir> voxcordis.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
; Keep this AppId forever: Windows uses it to find the app for upgrades.
AppId={{E25F035E-E4AD-4B5F-B5E5-0199735DFC64}
AppName=VoxCordis
AppVersion={#AppVersion}
AppVerName=VoxCordis {#AppVersion}
AppPublisher=Nucume
AppCopyright=Copyright (C) 2026 Nucume
DefaultDirName={autopf}\VoxCordis
DefaultGroupName=VoxCordis
DisableProgramGroupPage=yes
; Installs for the current user without admin rights unless they pick
; "all users" in the dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\companion.exe
OutputDir={#OutputDir}
OutputBaseFilename=VoxCordis-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\VoxCordis"; Filename: "{app}\companion.exe"
Name: "{autodesktop}\VoxCordis"; Filename: "{app}\companion.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\companion.exe"; Description: "{cm:LaunchProgram,VoxCordis}"; Flags: nowait postinstall skipifsilent
; The in-app updater runs this setup with /SILENT /update=1: start the app again.
Filename: "{app}\companion.exe"; Flags: nowait; Check: IsAppUpdate

[Code]
function IsAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:update|0}') = '1';
end;
