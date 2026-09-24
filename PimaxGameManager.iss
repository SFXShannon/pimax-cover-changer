; Pimax Game Manager installer (Inno Setup 6)
; Build: ISCC.exe /DAppVersion=X.Y.Z PimaxGameManager.iss   (build PimaxGameManager.exe first)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F2B7A51-3C9E-4D8A-9B1F-5E4C2A7D8B30}
AppName=Pimax Game Manager
AppVersion={#AppVersion}
AppVerName=Pimax Game Manager {#AppVersion}
AppPublisher=SFXShannon
AppPublisherURL=https://github.com/SFXShannon/pimax-game-manager
AppSupportURL=https://github.com/SFXShannon/pimax-game-manager/issues
AppUpdatesURL=https://github.com/SFXShannon/pimax-game-manager/releases
; Per-user install: no admin needed to install ({autopf} = %LOCALAPPDATA%\Programs). The app itself still asks for admin when it runs.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\Pimax Game Manager
DefaultGroupName=Pimax Game Manager
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=PimaxGameManagerSetup
SetupIconFile=PimaxGameManager.ico
UninstallDisplayIcon={app}\PimaxGameManager.exe
UninstallDisplayName=Pimax Game Manager
VersionInfoVersion={#AppVersion}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "PimaxGameManager.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\Pimax Game Manager"; Filename: "{app}\PimaxGameManager.exe"
Name: "{autodesktop}\Pimax Game Manager"; Filename: "{app}\PimaxGameManager.exe"; Tasks: desktopicon

[Run]
; shellexec so Windows can show the admin prompt the app needs
Filename: "{app}\PimaxGameManager.exe"; Description: "Start Pimax Game Manager"; Flags: postinstall nowait skipifsilent shellexec

; Uninstalling removes only the program files. Backups, covers and settings in %APPDATA%\PimaxGameManager are kept.
