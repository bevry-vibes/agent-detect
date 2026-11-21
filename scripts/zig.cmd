@echo off
rem scripts\zig.cmd — Windows entrypoint for the vendored Zig toolchain.
pwsh -NoProfile -File "%~dp0zig.ps1" %*
exit /b %ERRORLEVEL%
