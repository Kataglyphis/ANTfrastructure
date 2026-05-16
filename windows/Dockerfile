# escape=`
# Final Windows developer image built on top of the cached AI image.

ARG BASE_IMAGE=local/kataglyphis:windows-ai
FROM ${BASE_IMAGE}

ENTRYPOINT ["C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\Common7\\Tools\\VsDevCmd.bat","-arch=amd64","&&","powershell.exe","-NoLogo","-ExecutionPolicy","Bypass"]

