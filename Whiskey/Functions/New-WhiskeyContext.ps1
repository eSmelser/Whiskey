
function New-WhiskeyContext
{
    <#
    .SYNOPSIS
    Creates a context object to use when running builds.

    .DESCRIPTION
    The `New-WhiskeyContext` function creates a context object used when running builds. It gets passed to each build task. The YAML file at `ConfigurationPath` is parsed. If it has a `Version` property, it is converted to a semantic version, a classic version, and a NuGet verson (a semantic version without any build metadata). An object is then returned with the following properties:

    * `ConfigurationPath`: the absolute path to the YAML file passed via the `ConfigurationPath` parameter
    * `BuildRoot`: the absolute path to the directory the YAML configuration file is in.
    * `BuildConfiguration`: the build configuration to use when compiling code. Set from the parameter by the same name.
    * `OutputDirectory`: the path to a directory where build output, reports, etc. should be saved. This directory is created for you.
    * `Version`: a `SemVersion.SemanticVersion` object representing the semantic version to use when building the application. This object has two extended properties: `Version`, a `Version` object that represents the semantic version with all pre-release and build metadata stripped off; and `ReleaseVersion` a `SemVersion.SemanticVersion` object with all build metadata stripped off.
    * `ReleaseVersion`: the semantic version with all build metadata stripped away, i.e. the version and pre-release only.
    * `Configuration`: the parsed YAML as a hashtable.
    * `DownloadRoot`: the path to a directory where tools can be downloaded when needed. 
    * `ByBuildServer`: a flag indicating if the build is being run by a build server.
    * `ByDeveloper`: a flag indicating if the build is being run by a developer.
    * `ApplicatoinName`: the name of the application being built.

    In addition, if you're creating a context while running under a build server, you must supply BuildMaster, ProGet, and Bitbucket Server connection information. That connection information is returned in the following properties:

    * `BuildMasterSession`
    * `ProGetSession`
    * `BBServerConnection`

    .EXAMPLE
    New-WhiskeyContext -Path '.\whiskey.yml' -BuildConfiguration 'debug'

    Demonstrates how to create a context for a developer build.

    .EXAMPLE
    New-WhiskeyContext -Path '.\whiskey.yml' -BuildConfiguration 'debug' -BBServerCredential $bbCred -BBServerUri $bbUri -BuildMasterUri $bmUri -BuildMasterApiKey $bmApiKey -ProGetCredential $progetCred -ProGetUri $progetUri

    Demonstrates how to create a context for a build run by a build server.
    #>
    [CmdletBinding(DefaultParameterSetName='ByDeveloper')]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        # The environment you're building in.
        $Environment,

        [Parameter(Mandatory=$true)]
        [string]
        # The path to the `whiskey.yml` file that defines build settings and tasks.
        $ConfigurationPath,

        [Parameter(Mandatory=$true)]
        [string]
        # The configuration to use when compiling code, e.g. `Debug`, `Release`.
        $BuildConfiguration,

        [Parameter(Mandatory=$true,ParameterSetName='ByBuildServer')]
        [pscredential]
        # The credential to use when authenticating to Bitbucket Server. Required if running under a build server.
        $BBServerCredential,

        [Parameter(Mandatory=$true,ParameterSetName='ByBuildServer')]
        [uri]
        # The URI to Bitbucket Server. Required if running under a build server.
        $BBServerUri,

        [Parameter(Mandatory=$true,ParameterSetName='ByBuildServer')]
        [uri]
        # The URI to BuildMaster. Required if running under a build server.
        $BuildMasterUri,

        [Parameter(Mandatory=$true,ParameterSetName='ByBuildServer')]
        [string]
        # The API key to use when using BuildMaster's Release and Package Deployment API. Required if running under a build server.
        $BuildMasterApiKey,

        [Parameter(Mandatory=$true,ParameterSetName='ByBuildServer')]
        [pscredential]
        # The credential to use when authenticating to ProGet. Required if running under a build server.
        $ProGetCredential,

        [uri[]]
        # The URI to ProGet. Used to get Application Packages
        $ProGetAppFeedUri,

        [string]
        # The name/path to the feed in ProGet where universal application packages should be uploaded. The default is `upack/App`. Combined with the `ProGetUri` parameter to create the URI to the feed.
        $ProGetAppFeedName = 'Apps',

        [uri]
        # The URI to ProGet to get NuGet Packages
        $NuGetFeedUri,
        
        [uri]
        # The URI to ProGet to get PowerShell Modules
        $PowerShellFeedUri,
        
        [uri]
        # The URI to ProGet to get npm Packages
        $NpmFeedUri,

        [string]
        # The place where downloaded tools should be cached. The default is the build root.
        $DownloadRoot
    )

    Set-StrictMode -Version 'Latest'
    Use-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState

    $ConfigurationPath = Resolve-Path -LiteralPath $ConfigurationPath -ErrorAction Ignore
    if( -not $ConfigurationPath )
    {
        throw ('Configuration file path ''{0}'' does not exist.' -f $PSBoundParameters['ConfigurationPath'])
    }

    $config = Get-Content -Path $ConfigurationPath -Raw | ConvertFrom-Yaml
    if( -not $config )
    {
        $config = @{} 
    }

    $buildRoot = $ConfigurationPath | Split-Path
    if( -not $DownloadRoot )
    {
        $DownloadRoot = $buildRoot
    }

    $appName = $null
    if( $config.ContainsKey('ApplicationName') )
    {
        $appName = $config['ApplicationName']
    }

    $releaseName = $null
    if( $config.ContainsKey('ReleaseName') )
    {
        $releaseName = $config['ReleaseName']
    }

    $bitbucketConnection = $null
    $buildmasterSession = $null
    $progetSession = $null   
    $progetSession = [pscustomobject]@{
                                            
                                            Credential = $null;
                                            AppFeedUri = $ProGetAppFeedUri
                                            AppFeedName = $ProGetAppFeedName;
                                            NpmFeedUri = $NpmFeedUri;
                                            NuGetFeedUri = $NuGetFeedUri;
                                            PowerShellFeedUri = $PowerShellFeedUri;                                           
                                        }

    $publish = $false
    $byBuildServer = Test-WhiskeyRunByBuildServer
    $prereleaseInfo = ''
    if( $byBuildServer )
    {
        if( $PSCmdlet.ParameterSetName -ne 'ByBuildServer' )
        {
            throw (@"
New-WhiskeyContext is being run by a build server, but called using the developer parameter set. When running under a build server, you must supply the following parameters:

* BBServerCredential
* BBServerUri
* BuildMasterUri
* BuildMasterApiKey
* ProGetCredential
* ProGetUri

Use the `Test-WhiskeyRunByBuildServer` function to determine if you're running under a build server or not.
"@)
        }
        
        $branch = Get-WhiskeyBranch
        $publishOn = @( 'develop', 'release', 'release/.*', 'master' )
        if( $config.ContainsKey( 'PublishOn' ) )
        {
            $publishOn = $config['PublishOn']
        }

        $publish = ($branch -match ('^({0})$' -f ($publishOn -join '|')))
        if( -not $releaseName -and $publish )
        {
            $releaseName = $branch
        }

        $bitbucketConnection = New-BBServerConnection -Credential $BBServerCredential -Uri $BBServerUri
        $buildmasterSession = New-BMSession -Uri $BuildMasterUri -ApiKey $BuildMasterApiKey
        $progetSession.Credential = $ProGetCredential

        if( $config['PrereleaseMap'] )
        {
            Write-Verbose -Message ('Testing if {0} is a pre-release branch.' -f $branch)
            $idx = 0
            foreach( $item in $config['PrereleaseMap'] )
            {
                if( $item -isnot [hashtable] -or $item.Count -ne 1 )
                {
                    throw ('{0}: Prerelease[{1}]: The `PrereleaseMap` property must be a list of objects. Each object must have one property. That property should be a regular expression. The property''s value should be the prerelease identifier to add to the version number on branches that match the regular expression. For example,
    
    PrereleaseMap:
    - "\balpha\b": "alpha"
    - "\brc\b": "rc"
    ' -f $ConfigurationPath,$idx)
                }

                $regex = $item.Keys | Select-Object -First 1
                if( $branch -match $regex )
                {
                    Write-Verbose -Message ('     {0}     -match  /{1}/' -f $branch,$regex)
                    $prereleaseInfo = '{0}.{1}' -f $item[$regex],(Get-WhiskeyBuildID)
                }
                else
                {
                    Write-Verbose -Message ('     {0}  -notmatch  /{1}/' -f $branch,$regex)
                }
                $idx++
            }
        }
    }

    $packageJsonPath = Join-Path -Path $buildRoot -ChildPath 'package.json'
    $ignorePackageJsonVersion = $config.ContainsKey('IgnorePackageJsonVersion') -and $config['IgnorePackageJsonVersion']
    if( -not $config.ContainsKey('Version') -and (Test-Path -Path $packageJsonPath -PathType Leaf) -and -not $ignorePackageJsonVersion )
    {
        $config['Version'] = Get-Content -Raw -Path $packageJsonPath | ConvertFrom-Json | Select-Object -ExpandProperty 'version' -ErrorAction Ignore
        if( $config['Version'] -eq '0.0.0' )
        {
            $config.Remove('Version')
        }
    }

    [SemVersion.SemanticVersion]$semVersion = $config['Version'] | ConvertTo-WhiskeySemanticVersion -ErrorAction Ignore
    if( -not $semVersion )
    {
        throw ('{0}: Version: ''{1}'' is not a valid semantic version. Please see http://semver.org for semantic versioning documentation.' -f $ConfigurationPath,$config['Version'])
    }

    if( $prereleaseInfo )
    {
        $semVersion = New-Object 'SemVersion.SemanticVersion' $semVersion.Major,$semVersion.Minor,$semVersion.Patch,$prereleaseInfo,$semVersion.Build
    }

    $version = New-Object -TypeName 'version' -ArgumentList $semVersion.Major,$semVersion.Minor,$semVersion.Patch
    $semVersionNoBuild = New-Object -TypeName 'SemVersion.SemanticVersion' -ArgumentList $semVersion.Major,$semVersion.Minor,$semVersion.Patch
    $semVersionV1 = New-Object -TypeName 'SemVersion.SemanticVersion' -ArgumentList $semVersion.Major,$semVersion.Minor,$semVersion.Patch
    if( $semVersion.Prerelease )
    {
        $semVersionNoBuild = New-Object -TypeName 'SemVersion.SemanticVersion' -ArgumentList $semVersion.Major,$semVersion.Minor,$semVersion.Patch,$semVersion.Prerelease
        $semVersionV1Prerelease = $semVersion.Prerelease -replace '[^A-Za-z0-90]',''
        $semVersionV1 = New-Object -TypeName 'SemVersion.SemanticVersion' -ArgumentList $semVersion.Major,$semVersion.Minor,$semVersion.Patch,$semVersionV1Prerelease
    }
    
    $context = [pscustomobject]@{
                                    Environment = $Environment;
                                    Credentials = @{ }
                                    ApplicationName = $appName;
                                    ReleaseName = $releaseName;
                                    BuildRoot = $buildRoot;
                                    ConfigurationPath = $ConfigurationPath;
                                    BBServerConnection = $bitbucketConnection;
                                    BuildMasterSession = $buildmasterSession;
                                    ProGetSession = $progetSession;
                                    BuildConfiguration = $BuildConfiguration;
                                    OutputDirectory = (Get-WhiskeyOutputDirectory -WorkingDirectory $buildRoot);
                                    TaskName = $null;
                                    TaskIndex = -1;
                                    PackageVariables = @{};
                                    Version = [pscustomobject]@{
                                                                     SemVer2 = $semVersion;
                                                                     SemVer2NoBuildMetadata = $semVersionNoBuild;
                                                                     SemVer1 = $semVersionV1;
                                                                     Version = $version;
                                                                }
                                    Configuration = $config;
                                    DownloadRoot = $DownloadRoot;
                                    ByBuildServer = $byBuildServer;
                                    ByDeveloper = (-not $byBuildServer);
                                    Publish = $publish;
                                }
    return $context
}

