
function New-WhsCIAppPackage
{
    <#
    .SYNOPSIS
    Creates a WHS application deployment package.

    .DESCRIPTION
    The `New-WhsCIAppPackage` function creates an universal ProGet package for a WHS application, and optionally uploads it to ProGet and starts a deploy for the package in BuildMaster. The package should contain everything the application needs to install itself and run on any server it is deployed to, with minimal/no pre-requisites installed. To upload to ProGet and start a deploy, provide the packages's ProGet URI and credentials with the `ProGetPackageUri` and `ProGetCredential` parameters, respectively and a session to BuildMaster with the `BuildMasterSession` object.

    It returns an `IO.FileInfo` object for the created package.

    Packages are only allowed to have whitelisted files, i.e. you can't include all files by default. You must supply a value for the `Include` parameter that lists the file names or wildcards that match the files you want in your application.

    If the whitelist includes files that you want to exclude, or you want to omit certain directories, use the `Exclude` parameter. `New-WhsCIAppPackage` *always* excludes directories named:

     * `obj`
     * `.git`
     * `.hg`

    If the application doesn't exist exist in ProGet, it is created.

    The application must exist in BuildMaster and must have three releases: `develop` for deploying to Dev, `release` for deploying to Test, and `master` for deploying to Staging and Live. `New-WhsCIAppPackage` uses the current Git branch to determine which release to add the package to.
    #>
    [CmdletBinding(SupportsShouldProcess=$true,DefaultParameterSetName='NoUpload')]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        # The path to the root of the repository the application lives in.
        $RepositoryRoot,

        [Parameter(Mandatory=$true)]
        [string]
        # The name of the package being created.
        $Name,

        [Parameter(Mandatory=$true)]
        [string]
        # A description of the package.
        $Description,

        [Parameter(Mandatory=$true)]
        [SemVersion.SemanticVersion]
        # The package's version.
        $Version,

        [Parameter(Mandatory=$true)]
        [string[]]
        # The paths to include in the artifact. All items under directories are included.
        $Path,

        [Parameter(Mandatory=$true)]
        [string[]]
        # The whitelist of files to include in the artifact. Wildcards supported. Only files that match entries in this list are included in the package.
        $Include,

        [Parameter(Mandatory=$true,ParameterSetName='WithUpload')]
        [string]
        # The URI to the package's feed in ProGet. The package will be uploaded to this feed.
        $ProGetPackageUri,

        [Parameter(Mandatory=$true,ParameterSetName='WithUpload')]
        [pscredential]
        # The credential to use to upload the package to ProGet.
        $ProGetCredential,

        [Parameter(Mandatory=$true,ParameterSetName='WithUpload')]
        [object]
        # An object that represents the instance of BuildMaster to connect to.
        $BuildMasterSession,
        
        [string[]]
        # A list of files and/or directories to exclude. Wildcards supported. If any file or directory that would match a pattern in the `Include` list matches an item in this list, it is not included in the package.
        # 
        # `New-WhsCIAppPackage` will *always* exclude directories named:
        #
        # * .git
        # * .hg
        # * obj
        $Exclude
    )

    Set-StrictMode -Version 'Latest'
    Use-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState

    $resolveErrors = @()
    $Path = $Path | Resolve-Path -ErrorVariable 'resolveErrors' | Select-Object -ExpandProperty 'ProviderPath'
    if( $resolveErrors )
    {
        throw ('Unable to create ''{0}'' package. One or more of the paths to include in the package don''t exist.'-f $Name)
        return
    }

    $arcPath = Join-Path -Path $RepositoryRoot -ChildPath 'Arc'
    if( -not (Test-Path -Path $arcPath -PathType Container) )
    {
        throw ('Unable to create ''{0}'' package because the Arc platform ''{1}'' does not exist. Arc is required when using the WhsCI module to package your application. See https://confluence.webmd.net/display/WHS/Arc for instructions on how to integrate Arc into your repository.' -f $Name,$arcPath)
        return
    }

    $badChars = [IO.Path]::GetInvalidFileNameChars() | ForEach-Object { [regex]::Escape($_) }
    $fixRegex = '[{0}]' -f ($badChars -join '')
    $fileName = '{0}.{1}.upack' -f $Name,($Version -replace $fixRegex,'-')
    $outDirectory = Get-WhsCIOutputDirectory -WorkingDirectory $RepositoryRoot -WhatIf:$false

    $outFile = Join-Path -Path $outDirectory -ChildPath $fileName

    $tempRoot = [IO.Path]::GetRandomFileName()
    $tempBaseName = 'WhsCI+New-WhsCIAppPackage+{0}' -f $Name
    $tempRoot = '{0}+{1}' -f $tempBaseName,$tempRoot
    $tempRoot = Join-Path -Path $env:TEMP -ChildPath $tempRoot
    New-Item -Path $tempRoot -ItemType 'Directory' -WhatIf:$false | Out-String | Write-Verbose
    $tempPackageRoot = Join-Path -Path $tempRoot -ChildPath 'package'
    New-Item -Path $tempPackageRoot -ItemType 'Directory' -WhatIf:$false | Out-String | Write-Verbose

    try
    {
        $ciComponents = @(
                            'BitbucketServerAutomation', 
                            'Blade', 
                            'LibGit2', 
                            'LibGit2Adapter', 
                            'MSBuild',
                            'Pester', 
                            'PsHg',
                            'ReleaseTrain',
                            'WhsArtifacts',
                            'WhsHg',
                            'WhsPipeline'
                        )
        $arcDestination = Join-Path -Path $tempPackageRoot -ChildPath 'Arc'
        $excludedFiles = Get-ChildItem -Path $arcPath -File | 
                            ForEach-Object { '/XF'; $_.FullName }
        $excludedCIComponents = $ciComponents | ForEach-Object { '/XD' ; Join-Path -Path $arcPath -ChildPath $_ }
        $operationDescription = 'packaging Arc'
        $shouldProcessCaption = ('creating {0} package' -f $outFile)
        if( $PSCmdlet.ShouldProcess($operationDescription,$operationDescription,$shouldProcessCaption) )
        {
            robocopy $arcPath $arcDestination '/MIR' $excludedFiles $excludedCIComponents | Write-Debug
        }

        $upackJsonPath = Join-Path -Path $tempRoot -ChildPath 'upack.json'
        @{
            name = $Name;
            version = $Version.ToString();
            title = $Name;
            description = $Description
        } | ConvertTo-Json | Set-Content -Path $upackJsonPath -WhatIf:$false

        foreach( $item in $Path )
        {
            $itemName = $item | Split-Path -Leaf
            $destination = Join-Path -Path $tempPackageRoot -ChildPath $itemName
            $excludeParams = $Exclude | ForEach-Object { '/XF' ; $_ ; '/XD' ; $_ }
            $operationDescription = 'packaging {0}' -f $itemName
            if( $PSCmdlet.ShouldProcess($operationDescription,$operationDescription,$shouldProcessCaption) )
            {
                robocopy $item $destination /MIR $Include 'upack.json' $excludeParams '/XD' '.git' '/XD' '.hg' '/XD' 'obj' | Write-Debug
            }
        }

        Get-ChildItem -Path $tempRoot | Compress-Item -OutFile $outFile

        # Upload to ProGet
        $branch = (Get-Item -Path 'env:GIT_BRANCH').Value -replace '^origin/',''
        $branch = $branch -replace '/.*$',''
        if( $PSCmdlet.ParameterSetName -eq 'WithUpload' -and $branch -match '^(release|master|develop)$' )
        {
            $branch = $Matches[1]
            $headers = @{ }
            $bytes = [Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $ProGetCredential.UserName,$ProGetCredential.GetNetworkCredential().Password))
            $creds = 'Basic ' + [Convert]::ToBase64String($bytes)
            $headers.Add('Authorization', $creds)
    
            $operationDescription = 'uploading {0} package to ProGet {1}' -f ($outFile | Split-Path -Leaf),$ProGetPackageUri
            if( $PSCmdlet.ShouldProcess($operationDescription,$operationDescription,$shouldProcessCaption) )
            {
                $result = Invoke-RestMethod -Method Put `
                                            -Uri $ProGetPackageUri `
                                            -ContentType 'application/octet-stream' `
                                            -Body ([IO.File]::ReadAllBytes($outFile)) `
                                            -Headers $headers
                if( -not $? -or ($result -and $result.StatusCode -ne 201) )
                {
                    throw ('Failed to upload ''{0}'' package to {1}:{2}{3}' -f ($outFile | Split-Path -Leaf),$ProGetPackageUri,[Environment]::NewLine,($result | Format-List * -Force | Out-String))
                }
            }

            $release = Get-BMRelease -Session $BuildMasterSession -Application $Name -Name $branch
            $release | Format-List | Out-String | Write-Verbose
            $package = New-BMReleasePackage -Session $BuildMasterSession -Release $release -PackageNumber ('{0}.{1}' -f $Version.Patch,$branch) -Variable @{ 'ProGetPackageName' = $Version.ToString() }
            $package | Format-List | Out-String | Write-Verbose

            if( $branch -ne 'master' )
            {
                $deployment = Publish-BMReleasePackage -Session $BuildMasterSession -Package $package
                $deployment | Format-List | Out-String | Write-Verbose
            }
        }

        $shouldProcessDescription = ('returning package path ''{0}''' -f $outFile)
        if( $PSCmdlet.ShouldProcess($shouldProcessDescription, $shouldProcessDescription, $shouldProcessCaption) )
        {
            $outFile
        }
    }
    finally
    {
        Get-ChildItem -Path $env:TEMP -Filter ('{0}+*' -f $tempBaseName) |
            Remove-Item -Recurse -Force -WhatIf:$false
    }
}