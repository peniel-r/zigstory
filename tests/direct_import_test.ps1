$json = '[{"cmd":"echo test","cwd":"C:\\test","exit_code":0,"duration_ms":100}]'
$json | Out-File -FilePath "C:\temp\test.json" -Encoding utf8

& "F:\sandbox\zigstory\zig-out\bin\zigstory.exe" import --file "C:\temp\test.json" 2>&1

Write-Host "Exit code: $LASTEXITCODE"