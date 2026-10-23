@echo off
setlocal
if not defined VSINSTALLDIR call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
if not exist build mkdir build
cl /nologo /O2 /W4 /std:c11 /Fo:build\lz78-c.obj /Fe:build\lz78-c.exe benchmarks\lz78_c.c
if errorlevel 1 exit /b 1
cl /nologo /O2 /W4 /std:c11 /DCLASSIC_DEFAULT=1 /Fo:build\lz78-c-classic.obj /Fe:build\lz78-c-classic.exe benchmarks\lz78_c.c
exit /b %errorlevel%
