@echo off
chcp 65001 >nul 2>&1
title RenderDoc Build

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File .\build_full.ps1 %*

if %ERRORLEVEL% neq 0 (
    echo.
    echo 构建失败，按任意键退出...
    pause >nul
) else (
    echo.
    echo 构建完成，按任意键退出...
    pause >nul
)
