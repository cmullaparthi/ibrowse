@echo off
setlocal
set rebarscript=%~f0
"C:\Program Files (x86)\erl5.8.4\bin\escript.exe" "%rebarscript:.bat=%" %*
