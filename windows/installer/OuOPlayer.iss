; OuOPlayer's Windows installer (Inno Setup). scripts\release.ps1 builds it:
;   ISCC /DAppVersion=0.23.0 /DSourceDir=<the app's folder> /O<output> OuOPlayer.iss
; AppId must never change: updates find the installed copy by it.

[Setup]
AppId={{8F3A6C52-4B1E-4D7A-9C20-6E51D0B7A3F4}
AppName=OuOPlayer
AppVersion={#AppVersion}
AppPublisher=OuOPlayer
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\OuOPlayer
DefaultGroupName=OuOPlayer
DisableProgramGroupPage=yes
; For this user (no administrator) or for everyone: the installer asks.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=OuOPlayer-{#AppVersion}-windows-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\OuOPlayer.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "zh"; MessagesFile: "ChineseTraditional.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; In the Start menu, which is what Windows search looks through.
Name: "{autoprograms}\OuOPlayer"; Filename: "{app}\OuOPlayer.exe"
; Updates run silently: a shortcut the user removed stays removed.
Name: "{autodesktop}\OuOPlayer"; Filename: "{app}\OuOPlayer.exe"; Tasks: desktopicon; Check: not WizardSilent

[Run]
; Also after a silent update, so the app comes back by itself.
Filename: "{app}\OuOPlayer.exe"; Description: "{cm:LaunchProgram,OuOPlayer}"; Flags: nowait postinstall runasoriginaluser

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'OuOPlayer');
  if UninstallSilent then Exit;
  // The songs themselves are never touched; 否 is the default.
  if MsgBox('要一併刪除 OuOPlayer 的資料嗎？' #13#10 #13#10 '會刪除播放清單、歌詞、封面和設定，無法復原。歌曲檔案不會被刪除。' #13#10 #13#10 '選「否」會保留資料，重新安裝後還能使用。',
    mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(ExpandConstant('{userappdata}\com.ouo\OuOPlayer'), True, True, True);
end;
