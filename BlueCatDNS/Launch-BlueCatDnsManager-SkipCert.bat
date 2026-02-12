@echo off
:: BlueCat DNS Manager - Launcher (skip TLS cert validation)
:: Use this if your BAM uses a self-signed certificate
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0BlueCatDnsManager-GUI.ps1" -SkipCertCheck %*
