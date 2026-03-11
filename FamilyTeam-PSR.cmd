@echo off
pushd %~dp0
set /p "username=Account name: "
powershell -ExecutionPolicy Bypass -File .\FamilyTeam-PSR.ps1 -Username %username%
popd
@pause
