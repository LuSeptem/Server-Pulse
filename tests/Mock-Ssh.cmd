@echo off
setlocal EnableExtensions DisableDelayedExpansion
echo %* | findstr /C:"BatchMode=yes" >nul
if not errorlevel 1 (
  if /I "%SERVERPULSE_MOCK_BATCH%"=="ok" (
    echo SERVERPULSE_AUTH_OK
    exit /b 0
  )
  1>&2 echo Permission denied ^(publickey,password^).
  exit /b 255
)

set "MOCK_PASSWORD="
for /f "delims=" %%P in ('""%SSH_ASKPASS%" "password:""') do set "MOCK_PASSWORD=%%P"
if "%MOCK_PASSWORD%"=="mock-password" (
  echo SERVERPULSE_AUTH_OK
  exit /b 0
)
1>&2 echo Permission denied, please try again.
exit /b 255
