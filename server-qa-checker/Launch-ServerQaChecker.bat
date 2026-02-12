@echo off
:: Server QA Checker - Launcher
:: Double-click this file to launch the GUI
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0ServerQaChecker-GUI.ps1" %*
