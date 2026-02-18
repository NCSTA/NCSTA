@echo off
:: Server QA Checker - Run As Another User
:: Prompts for alternate credentials then launches the GUI under that account
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Launch-ServerQaChecker-RunAs.ps1"
