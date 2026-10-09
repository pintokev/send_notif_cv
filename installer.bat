@echo off
rem Installation guidee : double-cliquer sur ce fichier.
rem Version Windows de installer.sh : le travail est fait par scripts\windows.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows.ps1" installer
pause
