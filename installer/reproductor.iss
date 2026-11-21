; Instalador del Reproductor para Windows (Inno Setup 6).
; Lo compila GitHub Actions: ISCC /DAppVersion=0.1.3 /DAppVersionFull=0.1.3 /DSourceDir=... /DOutputDir=...

#define MyAppName "Reproductor"
#define MyAppExe "reproductor.exe"

[Setup]
AppId={{74E1B3CE-54B3-4699-B3CD-6180742811BA}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName={#MyAppName} v{#AppVersionFull}
AppPublisher=luchorcompartidos
AppPublisherURL=https://github.com/luchorcompartidos/reproductor
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=reproductor-setup-v{#AppVersionFull}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExe}
UninstallDisplayName={#MyAppName}
CloseApplications=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{group}\Desinstalar {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
