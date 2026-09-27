; Inno Setup script for MagniGlass (per-user install, no administrator rights needed).
; Built by .github/workflows/build.yml:  ISCC /DAppVersion=x.y.z /DSourceDir=..\publish installer\MagniGlass.iss

#define AppName "MagniGlass"
#define AppExe "MagniGlass.exe"
#ifndef AppVersion
  #define AppVersion "1.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\publish"
#endif

[Setup]
AppId={{8C3F2A61-4D7E-4B9A-A1C5-6E2F9D0B7A34}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Ax-Easy (Vangelis Makridakis)
AppPublisherURL=https://github.com/vagdesign/MagniGlass
DefaultDirName={localappdata}\Programs\MagniGlass
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=..\out
OutputBaseFilename=MagniGlass-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
SetupIconFile=..\win\MagniGlass\MagniGlass.ico
UninstallDisplayIcon={app}\{#AppExe}
WizardStyle=modern
CloseApplications=force
RestartApplications=no
LicenseFile=..\LICENSE

[Tasks]
Name: "startup"; Description: "Start MagniGlass when I sign in to Windows"; GroupDescription: "Options:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MagniGlass"; Filename: "{app}\{#AppExe}"
Name: "{autoprograms}\MagniGlass Settings"; Filename: "{app}\{#AppExe}"; Parameters: "--settings"
Name: "{autodesktop}\MagniGlass"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; The app keeps this value in step with its own "Start with Windows" setting.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "MagniGlass"; ValueData: """{app}\{#AppExe}"" --background"; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Parameters: "--settings"; Description: "Start MagniGlass now"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Parameters: "--background"; Flags: nowait skipifnotsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#AppExe}"; Flags: runhidden; RunOnceId: "StopMagniGlass"

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\MagniGlass"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  Settings: String;
begin
  // Tell the app which choice was made for "start when I sign in" (it owns the Run value).
  if CurStep = ssPostInstall then
  begin
    Settings := ExpandConstant('{userappdata}\MagniGlass\settings.json');
    if not FileExists(Settings) then
    begin
      ForceDirectories(ExtractFileDir(Settings));
      if WizardIsTaskSelected('startup') then
        SaveStringToFile(Settings, '{ "StartWithWindows": true }', False)
      else
        SaveStringToFile(Settings, '{ "StartWithWindows": false }', False);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'MagniGlass');
end;
