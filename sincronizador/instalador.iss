; Instalador do Aliber Financeiro (Inno Setup 6).
; O GitHub gera sozinho: iscc /DVERSAO=1.1 instalador.iss
; Instala para o usuário do Windows (sem pedir senha de administrador), para que a troca de
; versão pela área do técnico possa rodar em silêncio.
#ifndef VERSAO
  #define VERSAO "0.0"
#endif

[Setup]
AppId={{30969D36-1853-473E-BCC4-92BE51EC0F68}
AppName=Aliber Financeiro
AppVersion={#VERSAO}
AppVerName=Aliber Financeiro {#VERSAO}
AppPublisher=Aliber Informática / Sistemas
AppPublisherURL=https://marketingaliber.github.io/aliber-financeiro/
DefaultDirName={localappdata}\Programs\Aliber Financeiro
DefaultGroupName=Aliber Financeiro
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=AliberFinanceiro-Instalador
SetupIconFile=aliber.ico
UninstallDisplayIcon={app}\AliberFinanceiro.exe
UninstallDisplayName=Aliber Financeiro
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
VersionInfoVersion={#VERSAO}
VersionInfoCompany=Aliber Informática / Sistemas
VersionInfoDescription=Instalador do Aliber Financeiro

[Languages]
Name: "pt"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "iniciar"; Description: "Abrir sozinho quando o Windows ligar (recomendado)"; GroupDescription: "Opções:"
Name: "atalho"; Description: "Criar atalho na área de trabalho"; GroupDescription: "Opções:"

[InstallDelete]
; versão nova substitui os componentes inteiros (configuração fica em %APPDATA%, não aqui)
Type: filesandordirs; Name: "{app}\_internal"

[Files]
Source: "dist\AliberFinanceiro\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Aliber Financeiro"; Filename: "{app}\AliberFinanceiro.exe"
Name: "{group}\Painel online"; Filename: "https://marketingaliber.github.io/aliber-financeiro/"
Name: "{group}\Desinstalar o Aliber Financeiro"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Aliber Financeiro"; Filename: "{app}\AliberFinanceiro.exe"; Tasks: atalho

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Aliber Financeiro"; ValueData: """{app}\AliberFinanceiro.exe"" --minimizado"; Tasks: iniciar; Flags: uninsdeletevalue

[Run]
Filename: "{app}\AliberFinanceiro.exe"; Description: "Abrir o Aliber Financeiro agora"; Flags: nowait postinstall skipifsilent
Filename: "{app}\AliberFinanceiro.exe"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im AliberFinanceiro.exe"; Flags: runhidden; RunOnceId: "fechar"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var Codigo: Integer;
begin
  { fecha o programa aberto (inclusive o que chamou a atualização) antes de trocar os arquivos }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im AliberFinanceiro.exe', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Sleep(1500);
  Result := '';
end;
