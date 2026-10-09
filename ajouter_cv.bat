@echo off
rem Ajout d'une personne (CV + adresse mail) : double-cliquer sur ce fichier.
rem Version Windows de ajouter_cv.sh : le travail est fait par scripts\windows.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows.ps1" ajouter
pause
