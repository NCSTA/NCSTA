@echo off
:: Server QA Checker - Run As Another User
:: Prompts for a username then uses runas to launch the GUI under that account
:: Optional: pass DOMAIN\username as first argument to skip the prompt
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Launch-ServerQaChecker-RunAs.ps1" %*
