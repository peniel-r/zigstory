#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Quick runner: build zigstory then execute the functional test suite.
    Run from the repository root:

        pwsh -NoProfile -File tests/run_tests.ps1

    Pass extra flags through to the test script, e.g.:
        pwsh -NoProfile -File tests/run_tests.ps1 -Verbose -KeepDb
#>
param(
    [switch]$SkipBuild,
    [switch]$Verbose,
    [switch]$KeepDb
)

$here = $PSScriptRoot
& "$here\functional_tests.ps1" @PSBoundParameters
exit $LASTEXITCODE
