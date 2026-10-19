@echo off
chcp 65001 >nul
title 豆包语音历史 · 一键安装
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
pause
