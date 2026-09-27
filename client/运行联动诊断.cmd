@echo off
chcp 65001 >nul
title Siafeng 代理链路联动诊断
echo.
echo 请选择诊断模式：
echo   0. 快照（不抓包）
echo   1. XHTTP + REALITY
echo   2. Hysteria2
echo   3. AnyTLS
echo.
set /p choice=输入 0/1/2/3 后回车: 
if "%choice%"=="1" set node=XHTTP
if "%choice%"=="2" set node=HY2
if "%choice%"=="3" set node=AnyTLS
if "%choice%"=="0" set node=Snapshot
if not defined node (
  echo 选择无效。
  pause
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0proxy-link-diag.ps1" -Node %node% -CaptureSeconds 30
echo.
pause

