@echo off
chcp 65001 >nul
title Gerar instalador do Aliber Financeiro
rem Normalmente o GitHub gera sozinho. Use só para testar no seu computador.
rem Precisa do Python e do Inno Setup 6 (https://jrsoftware.org/isdl.php).
cd /d "%~dp0"
set "PY="
for %%V in (3.13 3.12 3.11) do (
  if not defined PY ( py -%%V --version >nul 2>nul && set "PY=py -%%V" )
)
if not defined PY set "PY=python"
%PY% -m pip install --upgrade -q -r requirements.txt pyinstaller
%PY% gerar_icone.py
%PY% -m PyInstaller --noconfirm --onedir --windowed --name AliberFinanceiro --icon aliber.ico --add-data "aliber.ico;." --add-data "marca.json;." --hidden-import testes.teste_resumo financeiro.py
"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DVERSAO=0.0.0 instalador.iss
echo.
echo Pronto: dist\AliberFinanceiro-Instalador.exe
pause
