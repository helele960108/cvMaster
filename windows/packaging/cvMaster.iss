#define AppName "cvMaster"
#define AppVersion "0.1.0"
#define AppPublisher "helele"
#define AppExeName "cvMaster.exe"

[Setup]
AppId={{8CF2E378-2CEB-415E-95A0-C39D8F359558}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/helele960108/cvMaster
AppSupportURL=https://github.com/helele960108/cvMaster
AppUpdatesURL=https://github.com/helele960108/cvMaster
DefaultDirName={localappdata}\Programs\cvMaster
DefaultGroupName=cvMaster
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist\installer
OutputBaseFilename=cvMaster-Setup-{#AppVersion}
SetupIconFile=..\src\CvMaster\Assets\app.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
AppMutex=Local\cvMaster.Instance
VersionInfoVersion=0.1.0.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=cvMaster Windows 安装程序
VersionInfoProductName={#AppName}
InfoBeforeFile=before-install.txt
ShowLanguageDialog=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "..\dist\win-x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\cvMaster"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Comment: "本地剪贴板历史"
Name: "{autodesktop}\cvMaster"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Comment: "本地剪贴板历史"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "启动 cvMaster"; Flags: nowait postinstall skipifsilent
