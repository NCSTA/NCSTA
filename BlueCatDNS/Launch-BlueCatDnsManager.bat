@echo off
:: BlueCat DNS Manager - Launcher
:: Double-click this file to launch the GUI
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0BlueCatDnsManager-GUI.ps1" %*
