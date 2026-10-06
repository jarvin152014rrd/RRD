@echo off
chcp 65001 >nul
echo === Instalando lo necesario para el verificador ===
where py >nul 2>nul
if errorlevel 1 (
  echo.
  echo No se encontro Python. Instalalo desde https://www.python.org/downloads/
  echo IMPORTANTE: marca la casilla "Add python.exe to PATH" al instalar.
  pause
  exit /b
)
py -m pip install --upgrade playwright openpyxl
py -m playwright install chromium
echo.
echo Listo. Ahora usa ejecutar.bat
pause
