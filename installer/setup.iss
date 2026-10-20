#define MyAppName "豆包语音历史"
#define MyAppVersion "2.5.2"
#define MyAppPublisher "xiaochen08"
#define MyAppURL "https://github.com/xiaochen08/doubao-voice-history"

[Setup]
AppId={{A7C3E5B2-6F4D-4A1E-9B7C-2D8F1E6A4C90}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\DoubaoVoiceHistory\app
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename=DoubaoVoiceHistory-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
UninstallDisplayName={#MyAppName}

[Files]
Source: "VoiceHistory.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Doctor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Update.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "VersionWatch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Patch-Ime.ps1"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "Install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "VERSION.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "update.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "voicehook.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "安装说明.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "Stop-App.ps1"; Flags: dontcopy

[Icons]
Name: "{group}\豆包语音历史"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\VoiceHistory.ps1"""; WorkingDir: "{app}"
Name: "{group}\诊断与修复"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Doctor.ps1"" -Fix"; WorkingDir: "{app}"
Name: "{group}\卸载豆包语音历史"; Filename: "{uninstallexe}"
Name: "{autodesktop}\豆包语音历史"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\VoiceHistory.ps1"""; WorkingDir: "{app}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install.ps1"" -Silent"; Flags: runhidden waituntilterminated; StatusMsg: "正在配置自启、版本监控与自动更新..."

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall.ps1"" -KeepApp"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveTasks"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    ExtractTemporaryFile('Stop-App.ps1');
    Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\Stop-App.ps1') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
