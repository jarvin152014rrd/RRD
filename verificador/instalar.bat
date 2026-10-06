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
py -m pip install --upgrade "playwright>=1.40,<2" "openpyxl>=3.1,<4" "pypdf>=4,<7" "xlrd>=2,<3" "defusedxml>=0.7,<1" "anthropic>=1.11,<2"
py -m playwright install chromium
echo.
echo Listo. Ahora usa ejecutar.bat
pause
