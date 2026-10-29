@echo off
setlocal
set "HERMES_HOME="
hermes -p default chat --provider qwen --model qwen3.8-27b %*
exit /b %errorlevel%
