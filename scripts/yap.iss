; The Windows installer (Inno Setup 6 or 7): yap, and optionally the screen
; sharing add-on next to it (D12 in misc/hq-share/README.md). The server
; and the web build stay in the zip.
;
; It installs for the current user (%LOCALAPPDATA%\Programs\Yap, no
; administrator needed) unless asked for everyone. Its Start menu
; shortcut is the one the client's own Install button makes
; (settings/install_windows.odin), so the client shows it as installed.
; Everything the client keeps (settings, known servers, its key, the
; image cache) is in %LOCALAPPDATA%\yap; uninstalling asks whether to
; remove that too, and leaves it when run silently.
;
; Built by scripts/package-windows.sh after package.sh and
; package-video.sh; the defines below are what it passes.

#ifndef AppVersion
  #define AppVersion "dev"
#endif
#ifndef ClientDir
  #define ClientDir SourcePath + "..\dist\yap-windows-x64"
#endif
#ifndef VideoDir
  #define VideoDir SourcePath + "..\dist\yap-video-windows-x64"
#endif
#ifndef OutputName
  #define OutputName "Yap-Setup-x64"
#endif

[Setup]
AppId={{E940E0EE-63CE-462C-9878-9DAB0A06424E}
AppName=Yap
AppVersion={#AppVersion}
AppVerName=Yap {#AppVersion}
AppPublisher=univrsal
AppPublisherURL=https://github.com/univrsal/yap
DefaultDirName={autopf}\Yap
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#SourcePath}..\dist
OutputBaseFilename={#OutputName}
SetupIconFile={#SourcePath}..\src\client\assets\icon.ico
UninstallDisplayIcon={app}\yap.exe
UninstallDisplayName=Yap
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Types]
Name: "full"; Description: "Yap with screen sharing"
Name: "client"; Description: "Just Yap, without screen sharing"
; Lets the components be ticked one by one, and /COMPONENTS work.
Name: "custom"; Description: "Custom"; Flags: iscustom

[Components]
Name: "client"; Description: "Yap"; Types: full client; Flags: fixed
Name: "video"; Description: "Screen sharing (FFmpeg); can be added later by running this again"; Types: full

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#ClientDir}\yap.exe"; DestDir: "{app}"; Components: client; Flags: ignoreversion
; The add-on's README says to unpack it next to yap, which this does.
Source: "{#VideoDir}\*"; Excludes: "README.txt"; DestDir: "{app}"; Components: video; Flags: ignoreversion

[InstallDelete]
; Running it again without screen sharing takes the add-on out again.
Type: files; Name: "{app}\yap_video.dll"; Components: not video
Type: files; Name: "{app}\yv-loopback.exe"; Components: not video
Type: files; Name: "{app}\avcodec-*.dll"; Components: not video
Type: files; Name: "{app}\avutil-*.dll"; Components: not video
Type: files; Name: "{app}\swresample-*.dll"; Components: not video
Type: files; Name: "{app}\swscale-*.dll"; Components: not video
Type: files; Name: "{app}\ffmpeg-LICENSE.txt"; Components: not video

[Icons]
Name: "{autoprograms}\Yap"; Filename: "{app}\yap.exe"; WorkingDir: "{app}"; Comment: "Voice chat"
Name: "{autodesktop}\Yap"; Filename: "{app}\yap.exe"; WorkingDir: "{app}"; Comment: "Voice chat"; Tasks: desktopicon

[Run]
Filename: "{app}\yap.exe"; Description: "{cm:LaunchProgram,Yap}"; Flags: nowait postinstall skipifsilent

[Code]
// After uninstalling, offer to remove what the client keeps as well
// (platform/config_path_native.odin, conn/image_cache_native.odin).
// No is the default, so a reinstall picks up where it left off.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: String;
begin
  if (CurUninstallStep <> usPostUninstall) or UninstallSilent then
    Exit;
  Dir := ExpandConstant('{localappdata}\yap');
  if not DirExists(Dir) then
    Exit;
  if MsgBox('Also remove your yap settings?' + #13#10#13#10 +
      'This deletes ' + Dir + ': your settings, the servers you''ve connected to, ' +
      'this computer''s key and the cached images. Keep them if you might ' +
      'install yap again.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(Dir, True, True, True);
end;
