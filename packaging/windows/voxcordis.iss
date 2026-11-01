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
; Who and what the setup program is, shown in its file properties. An
; installer with none of this looks anonymous to antivirus engines.
VersionInfoCompany=Nucume
VersionInfoDescription=VoxCordis Setup
VersionInfoCopyright=Copyright (C) 2026 Nucume
VersionInfoProductName=VoxCordis
VersionInfoProductTextVersion={#AppVersion}
AppPublisherURL=https://voxcordisai.com
AppSupportURL=https://github.com/Nucume/VoxCordis/issues
AppUpdatesURL=https://github.com/Nucume/VoxCordis/releases
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
UninstallDisplayIcon={app}\voxcordisai.exe
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

; The program was called companion.exe in older versions: remove it on update.
[InstallDelete]
Type: files; Name: "{app}\companion.exe"

[Icons]
Name: "{autoprograms}\VoxCordis"; Filename: "{app}\voxcordisai.exe"
Name: "{autodesktop}\VoxCordis"; Filename: "{app}\voxcordisai.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\voxcordisai.exe"; Description: "{cm:LaunchProgram,VoxCordis}"; Flags: nowait postinstall skipifsilent
; The in-app updater runs this setup with /SILENT /update=1: start the app again.
Filename: "{app}\voxcordisai.exe"; Flags: nowait; Check: IsAppUpdate

[Code]
function IsAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:update|0}') = '1';
end;

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

{ "Start with the computer" (written by the app) names the program, which
  was companion.exe before it became voxcordisai.exe; this setup deletes
  the old file, so point the entry at the new one. Otherwise VoxCordis would
  not start at login until it had been opened once by hand. }
procedure CurStepChanged(CurStep: TSetupStep);
var
  Command: String;
begin
  if CurStep <> ssPostInstall then Exit;
  if RegQueryStringValue(HKCU, RunKey, 'VoxCordis', Command) and
     (Pos('\companion.exe', Command) > 0) then
  begin
    StringChangeEx(Command, '\companion.exe', '\voxcordisai.exe', True);
    RegWriteStringValue(HKCU, RunKey, 'VoxCordis', Command);
  end;
end;
