##########################################################################
# Copyright 2017 Amazon.com, Inc. and its affiliates. All Rights Reserved.
#
# Licensed under the MIT License. See the LICENSE accompanying this file
# for the specific language governing permissions and limitations under
# the License.
##########################################################################

[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
Import-VstsLocStrings "$PSScriptRoot\task.json"

# script snippets we'll inject
$installCheckSnippet = @(
    "Write-Host " + (Get-VstsLocString -Key 'TestingModuleInstalled')
    "if (!(Get-Module -Name AWSPowerShell -ListAvailable))"
    "{"
        "    Write-Host " + (Get-VstsLocString -Key 'InstallingModule')
        "    Install-PackageProvider -Name NuGet -Scope CurrentUser -Verbose -Force"
        "    Install-Module -Name AWSPowerShell -Scope CurrentUser -Verbose -Force"
    "}"
)

$metricsSnippet = @(
    "Set-Item -Path env:AWS_EXECUTION_ENV -Value 'VSTS-AWSPowerShellModuleScript'"
)

# Adapting code from the VSTS-Tasks 'PowerShell' task to construct an overall
# script containing our install test, metrics setup, credential and region context
# and finally the user supplied script, which we hand off to PowerShell to run.
try
{
    $awsEndpoint = Get-VstsInput -Name 'awsCredentials' -Require
    $awsEndpointAuth = Get-VstsEndpoint -Name $awsEndpoint -Require
    $awsRegion = Get-VstsInput -Name 'regionName' -Require
    $scriptType = Get-VstsInput -Name 'scriptType' -Require

    $input_errorActionPreference = Get-VstsInput -Name 'errorActionPreference' -Default 'Stop'
    switch ($input_errorActionPreference.ToUpperInvariant())
    {
        'STOP' { }
        'CONTINUE' { }
        'SILENTLYCONTINUE' { }
        default
        {
            Write-Error (Get-VstsLocString -Key 'PS_InvalidErrorActionPreference' -ArgumentList $input_errorActionPreference)
        }
    }

    $input_failOnStderr = Get-VstsInput -Name 'failOnStderr' -AsBool
    $input_ignoreLASTEXITCODE = Get-VstsInput -Name 'ignoreLASTEXITCODE' -AsBool
    $input_workingDirectory = Get-VstsInput -Name 'workingDirectory' -Require
    Assert-VstsPath -LiteralPath $input_workingDirectory -PathType 'Container'

    $scriptType = Get-VstsInput -Name 'scriptType' -Require
    if ("$scriptType".ToUpperInvariant() -eq "FILEPATH")
    {
        $input_filePath = Get-VstsInput -Name 'filePath' -Require
        try
        {
            Assert-VstsPath -LiteralPath $input_filePath -PathType Leaf
        } catch
        {
            Write-Error (Get-VstsLocString -Key 'PS_InvalidFilePath' -ArgumentList $input_filePath)
        }

        if (!$input_filePath.ToUpperInvariant().EndsWith('.PS1'))
        {
            Write-Error (Get-VstsLocString -Key 'PS_InvalidFilePath' -ArgumentList $input_filePath)
        }

        $input_arguments = Get-VstsInput -Name 'arguments'
    }
    else
    {
        $input_script = Get-VstsInput -Name 'inlineScript' -Require
    }

    # Generate the script contents.
    Write-Host (Get-VstsLocString -Key 'GeneratingScript')
    $contents = @()
    $contents += "`$ErrorActionPreference = '$input_errorActionPreference'"

    $contents += $installCheckSnippet
    $contents += $metricsSnippet

    $contents += "Write-Host " + (Get-VstsLocString -Key 'InitializingContext' -ArgumentList $awsRegion)
    $contents += "Set-AWSCredential -AccessKey $($awsEndpointAuth.Auth.Parameters.UserName) -SecretKey $($awsEndpointAuth.Auth.Parameters.Password)"
    $contents += "Set-DefaultAWSRegion $awsRegion"

    if ("$input_targetType".ToUpperInvariant() -eq 'FILEPATH')
    {
        $contents += ". '$("$input_filePath".Replace("'", "''"))' $input_arguments".Trim()
        Write-Host (Get-VstsLocString -Key 'PS_FormattedCommand' -ArgumentList ($contents[-1]))
    }
    else
    {
        $contents += "$input_script".Replace("`r`n", "`n").Replace("`n", "`r`n")
    }

    if (!$input_ignoreLASTEXITCODE)
    {
        $contents += 'if (!(Test-Path -LiteralPath variable:\LASTEXITCODE)) {'
        $contents += '    Write-Host ''##vso[task.debug]$LASTEXITCODE is not set.'''
        $contents += '} else {'
        $contents += '    Write-Host (''##vso[task.debug]$LASTEXITCODE: {0}'' -f $LASTEXITCODE)'
        $contents += '    exit $LASTEXITCODE'
        $contents += '}'
    }

    # Write the script to disk.
    Assert-VstsAgent -Minimum '2.115.0'
    $tempDirectory = Get-VstsTaskVariable -Name 'agent.tempDirectory' -Require
    Assert-VstsPath -LiteralPath $tempDirectory -PathType 'Container'
    $filePath = [System.IO.Path]::Combine($tempDirectory, "$([System.Guid]::NewGuid()).ps1")
    $joinedContents = [System.String]::Join(([System.Environment]::NewLine), $contents)
    $null = [System.IO.File]::WriteAllText($filePath, $joinedContents, ([System.Text.Encoding]::UTF8))

    # Prepare the external command values.
    $powershellPath = Get-Command -Name powershell.exe -CommandType Application | Select-Object -First 1 -ExpandProperty Path
    Assert-VstsPath -LiteralPath $powershellPath -PathType 'Leaf'
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -File `"$filePath`""
    $splat = @{
        'FileName' = $powershellPath
        'Arguments' = $arguments
        'WorkingDirectory' = $input_workingDirectory
    }

    # Switch to "Continue".
    $global:ErrorActionPreference = 'Continue'
    $failed = $false

    # Run the script.
    if (!$input_failOnStderr)
    {
        Invoke-VstsTool @splat
    }
    else
    {
        $inError = $false
        $errorLines = New-Object System.Text.StringBuilder
        Invoke-VstsTool @splat 2>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord])
                {
                    # Buffer the error lines.
                    $failed = $true
                    $inError = $true
                    $null = $errorLines.AppendLine("$($_.Exception.Message)")

                    # Write to verbose to mitigate if the process hangs.
                    Write-Verbose "STDERR: $($_.Exception.Message)"
                }
                else
                {
                    # Flush the error buffer.
                    if ($inError)
                    {
                        $inError = $false
                        $message = $errorLines.ToString().Trim()
                        $null = $errorLines.Clear()
                        if ($message)
                        {
                            Write-VstsTaskError -Message $message
                        }
                    }

                    Write-Host "$_"
                }
            }

        # Flush the error buffer one last time.
        if ($inError)
        {
            $inError = $false
            $message = $errorLines.ToString().Trim()
            $null = $errorLines.Clear()
            if ($message)
            {
                Write-VstsTaskError -Message $message
            }
        }
    }

    # Fail on $LASTEXITCODE
    if (!(Test-Path -LiteralPath 'variable:\LASTEXITCODE'))
    {
        $failed = $true
        Write-Verbose "Unable to determine exit code"
        Write-VstsTaskError -Message (Get-VstsLocString -Key 'PS_UnableToDetermineExitCode')
    }
    else
    {
        if ($LASTEXITCODE -ne 0)
        {
            $failed = $true
            Write-VstsTaskError -Message (Get-VstsLocString -Key 'PS_ExitCode' -ArgumentList $LASTEXITCODE)
        }
    }

    # Fail if any errors.
    if ($failed)
    {
        Write-VstsSetResult -Result 'Failed' -Message "Error detected" -DoNotThrow
    }
}
finally
{
    Trace-VstsLeavingInvocation $MyInvocation
}
