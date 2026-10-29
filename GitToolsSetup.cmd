@echo off
chcp 65001 >nul
rem Launcher for GitToolsSetup.ps1 (scriptblock bypasses the security prompt on a network drive)
powershell -NoProfile -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~dp0GitToolsSetup.ps1' -Raw -Encoding UTF8))) -ScriptDir '%~dp0'"
pause
