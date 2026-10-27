@echo off
chcp 65001 >nul
title Gerar AliberFinanceiro.exe
cd /d "%~dp0"
set "PY="
for %%V in (3.13 3.12 3.11) do (
  if not defined PY ( py -%%V --version >nul 2>nul && set "PY=py -%%V" )
)
if not defined PY set "PY=python"
%PY% -m pip install --upgrade -q -r requirements.txt pyinstaller
%PY% gerar_icone.py
%PY% -m PyInstaller --noconfirm --onefile --windowed --name AliberFinanceiro --icon aliber.ico --add-data "aliber.ico;." --hidden-import testes.teste_resumo financeiro.py
echo.
echo Pronto: o programa esta em  dist\AliberFinanceiro.exe
pause
