@echo off
setlocal EnableExtensions DisableDelayedExpansion
if /I "%SERVERPULSE_MOCK_PERSISTENT%"=="1" goto persistent_start
if /I "%SERVERPULSE_MOCK_PERSISTENT%"=="fail" goto persistent_fail
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
  if /I "%SERVERPULSE_MOCK_PERSISTENT%"=="password" goto persistent_start
  echo SERVERPULSE_AUTH_OK
  exit /b 0
)
1>&2 echo Permission denied, please try again.
exit /b 255

:persistent_start
>>"%SERVERPULSE_MOCK_COUNT_FILE%" echo started
more >nul
:persistent_loop
echo __SERVERPULSE_SAMPLE_BEGIN__
echo PROTOCOL_VERSION=2
echo HOSTNAME=mock-persistent
echo CPU_PERCENT=10.0
echo MEM_TOTAL_KIB=1048576
echo MEM_USED_KIB=262144
echo MEM_PERCENT=25.0
echo LOAD_1=0.10
echo LOAD_5=0.20
echo LOAD_15=0.30
echo UPTIME_SECONDS=60
echo CPU_USER_STATUS=unavailable
echo CPU_USER_SKIPPED=0
echo MEMORY_USER_STATUS=unavailable
echo MEMORY_USER_SKIPPED=0
echo GPUS_BEGIN
echo GPUS_END
echo GPU_USER_STATUS=unavailable
echo __SERVERPULSE_SAMPLE_END__ 0
ping -n 2 127.0.0.1 >nul
goto persistent_loop

:persistent_fail
>>"%SERVERPULSE_MOCK_COUNT_FILE%" echo started
more >nul
1>&2 echo ssh: connect to host mock port 22: Connection refused
exit /b 255
