@echo off
chcp 65001 >nul
rem Spoustec GitToolsSetup.ps1 (scriptblock obchazi bezpecnostni dotaz na sitovem disku)
powershell -NoProfile -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~dp0GitToolsSetup.ps1' -Raw -Encoding UTF8))) -ScriptDir '%~dp0'"
pause
