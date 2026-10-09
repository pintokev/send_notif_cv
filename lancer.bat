@echo off
rem Recherche a la demande, envoi automatique : double-cliquer sur ce fichier.
rem Version Windows de lancer.sh : le travail est fait par scripts\windows.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows.ps1" lancer %*
pause
