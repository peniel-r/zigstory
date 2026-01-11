# Quick test for predictor instantiation
Add-Type -Path "$PSScriptRoot\..\src\predictor\bin\Release\net8.0\zigstoryPredictor.dll"

try {
    $p = New-Object zigstoryPredictor.ZigstoryPredictor
    Write-Host "Success: Predictor created"
    Write-Host "Id: $($p.Id)"
    Write-Host "Name: $($p.Name)"
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "Inner: $($_.Exception.InnerException.Message)"
}
