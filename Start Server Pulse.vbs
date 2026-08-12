Option Explicit
Dim shell, fso, root, command, executable
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
executable = root & "\ServerPulse.exe"
If fso.FileExists(executable) Then
    command = Chr(34) & executable & Chr(34)
Else
    command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & root & "\ServerPulse.ps1" & Chr(34)
End If
shell.Run command, 0, False
