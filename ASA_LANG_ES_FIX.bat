@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "ACTION=%~1"
if /i "%ACTION%"=="install" goto RUN_INSTALL
if /i "%ACTION%"=="diagnostic" goto RUN_DIAGNOSTIC
if /i "%ACTION%"=="revert" goto RUN_REVERT

:MENU
cls
echo =============================================================
echo  LANG_ES_FIX - INSTALAR / DIAGNOSTICAR / REVERTIR
echo =============================================================
echo.
echo  1. Crear, verificar e INSTALAR EL PARCHE
echo  2. Crear y verificar SIN INSTALAR
echo  3. REVERTIR EL PARCHE y restaurar el estado anterior
echo  4. Salir
echo.
set "CHOICE="
set /p "CHOICE=Elige una opcion [1-4]: "
if "%CHOICE%"=="1" goto RUN_INSTALL
if "%CHOICE%"=="2" goto RUN_DIAGNOSTIC
if "%CHOICE%"=="3" goto RUN_REVERT
if "%CHOICE%"=="4" exit /b 0
goto MENU

:RUN_INSTALL
set "ACTION=Install"
goto RUN

:RUN_DIAGNOSTIC
set "ACTION=Diagnostic"
goto RUN

:RUN_REVERT
set "ACTION=Revert"
goto RUN

:RUN
echo.
echo Ejecutando accion: %ACTION%
echo Cierra ARK completamente antes de continuar.
echo.

if /i "%ACTION%"=="Diagnostic" goto EXECUTE
fltmc >nul 2>&1
if "%ERRORLEVEL%"=="0" goto EXECUTE
echo Solicitando permisos de administrador para %ACTION%...
set "FIX_BAT=%~f0"
set "FIX_ACTION=%ACTION%"
powershell.exe -NoProfile -Command "Start-Process -FilePath $env:FIX_BAT -ArgumentList $env:FIX_ACTION -Verb RunAs"
if errorlevel 1 (
  echo ERROR: no se pudo solicitar la elevacion UAC.
  pause
  exit /b 1
)
exit /b 0

:EXECUTE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\LANG_ES_FIX.ps1" -Action %ACTION%
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo ERROR: la accion %ACTION% no se completo.
  echo Revisa RESULTADO_ULTIMA_EJECUCION\INSTALACION_FIX.log.txt
) else (
  echo ACCION %ACTION% COMPLETADA.
)
echo.
pause
goto MENU
