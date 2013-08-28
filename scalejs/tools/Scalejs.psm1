#$ErrorActionPreference = "Stop"

function Resolve-ProjectName {
    param(
        [parameter(ValueFromPipelineByPropertyName = $true)]
        [string[]]$ProjectName
	)

    if($ProjectName) {
        $projects = Get-Project $ProjectName
    }
    else {
        # All projects by default
        $projects = Get-Project
    }
    
    $projects
}

function Get-MSBuildProject {
    param(
        [parameter(ValueFromPipelineByPropertyName = $true)]
        [string[]]$ProjectName
    )
    Process {
        (Resolve-ProjectName $ProjectName) | % {
            $path = $_.FullName
            @([Microsoft.Build.Evaluation.ProjectCollection]::GlobalProjectCollection.GetLoadedProjects($path))[0]
        }
    }
}

function Add-Import {
    param(
        [parameter(Position = 0, Mandatory = $true)]
        [string]$Path,
        [parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$ProjectName
    )
	
	(Resolve-ProjectName $ProjectName) | %{
		$buildProject = $_ | Get-MSBuildProject
		$import = $buildProject.Xml.Imports | Where-Object { $_.Project -eq $Path }
		if (!$import) {
			$buildProject.Xml.AddImport($Path) | Out-Null
			$_.Save()
		}
	}

	$Input
}

function Remove-Import {
    param(
        [parameter(Position = 0, Mandatory = $true)]
        [string]$Path,
        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$ProjectName
    )
    (Resolve-ProjectName $ProjectName) | %{
        $buildProject = $_ | Get-MSBuildProject
		$imports = $buildProject.Xml.Imports | Where-Object { $_.Project -eq $Path } 
		if ($imports) {
			$imports | ForEach-Object { $buildProject.Xml.RemoveChild($_) | Out-Null }
            $_.Save() | Out-Null
		}
    }
	$Input
}

function Get-InstallPath {
    param(
        $package
    )
    # Get the repository path
    $componentModel = Get-VSComponentModel
    $repositorySettings = $componentModel.GetService([NuGet.VisualStudio.IRepositorySettings])
    $pathResolver = New-Object NuGet.DefaultPackagePathResolver($repositorySettings.RepositoryPath)
    $pathResolver.GetInstallPath($package)
}

function Get-SolutionDir {
    if($dte.Solution -and $dte.Solution.IsOpen) {
        return Split-Path $dte.Solution.Properties.Item("Path").Value
    }
    else {
        throw "Solution not avaliable"
    }
}

function Get-Config {
	param(
        [string]$ProjectName
	)
	$projectDir = Split-Path (Get-Project $ProjectName).FullName

    return "$projectDir\config.js"
}
 
function Test-Config {
	param([string] $ProjectName)
	
	Test-Path (Get-Config $ProjectName)
}

function Read-Config {
	param([string] $ProjectName)

	$configPath = Get-Config $ProjectName
	$config = (Get-Content $configPath) 
 
	$match = [regex]::Match($config, "require\s*=\s*({.*})\s*;", [System.Text.RegularExpressions.RegexOptions]::Singleline)
	
	if ($match.Success) {
		return ,(ConvertFrom-Json $match.Groups[1].Value)
	} 
	throw "Invalid config content in $configPath"
	
}

function ConvertTo-Ordered {
    param (
        [parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [object] $Obj
    )

    $properties = $Obj | Get-Member -MemberType NoteProperty |% { $_.Name }
    $Obj | Select-Object -Property $properties

}

function Write-Config {
 	param (
		[object] $Config,
		[string] $ProjectName
	)

    if ($Config.paths) {
        $Config | Add-Member 'paths' (ConvertTo-Ordered $Config.paths) -Force
    }
    
    if ($Config.scalejs.extensions.length -gt 1) {
        $Config.scalejs | Add-Member 'extensions' ($Config.scalejs.extensions | Sort-Object) -Force
    }

    if ($Config.shim -ne $null -and ($Config.shim | Get-Member -MemberType NoteProperty).Count -gt 1) {
        $Config | Add-Member 'shim' (ConvertTo-Ordered $Config.shim) -Force
    }

    $Config = ConvertTo-Ordered $Config

	$configJson = ConvertTo-Json $Config -Depth 10

	$indent = ""
	$configJson = $configJson.split("`n") |
        Where-Object { $_.Trim() -ne '' } |% {
        $trimmed = $_.Trim()
        if ($trimmed -match '[}\]],?$') {
			$indent = $indent.Substring(0, $indent.Length - 4)
        }
		$indent + $trimmed
		if ($trimmed -match '[{\[]$') {
			$indent = $indent + '    '
		} 
	} | Out-String

    $configPath = Get-Config $ProjectName
	$scalejsProjectType = Get-ScalejsProjectType $ProjectName

	$config = @"
var require = $($configJson.Trim());
"@

    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content $tmp $config
    Move-Item $tmp $configPath -force
}
 
function Add-Paths {
 	param (
		[parameter(Position = 0, Mandatory = $true)]
		[string] $PathsJson,

        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)

	if (Test-Config $ProjectName) {
        $config = Read-Config $ProjectName

        if (!$config.paths) {
            $config | Add-Member 'paths' [pscustomobject]@{}
        }
        $configPaths = $config.paths

        $paths = ConvertFrom-Json $PathsJson

        $paths | Get-Member -MemberType NoteProperty |% {
            $path = $_.Name
            $value = $paths."$path"
            if (-not $configPaths."$path") {
                $configPaths | Add-Member $path $value
            }
        }
        
        Write-Config $config $ProjectName
    }

    $Input
}

function Remove-Paths {
 	param (
        [parameter(Position = 0, Mandatory = $true)]
		[string] $PathsString,

        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)
	
	if (Test-Config $ProjectName) {
        $paths = [regex]::split($PathsString, ',|\s') | Where-Object { $_ }
		
        $config = Read-Config $ProjectName
        if ($config.paths) {
            $configPaths = $config.paths | Select -Property * -ExcludeProperty $Paths
			if (($configPaths | Get-Member -MemberType NoteProperty).Name -eq '*') {
				$configPaths = $configPaths | Select -Property * -ExcludeProperty *
			}
            $Config | Add-Member 'paths' $configPaths -Force
        }
        
        Write-Config $config $ProjectName
    }

    $Input
}
 
function Add-Shims {
 	param (
		[parameter(Position = 0, Mandatory = $true)]
		[string] $ShimsJson,

        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)		
	
	if (Test-Config $ProjectName) {
        $config = Read-Config $ProjectName
        
        $shims = ConvertFrom-Json $ShimsJson
        if ($config.shim) {
            $shims | Get-Member -MemberType NoteProperty |% {
                $shim = $_.Name
                $value = $shims."$shim"
                if (-not $config.shim."$shim") {
                    $config.shim | Add-Member $shim $value
                }
            }
        } else {
            $config | Add-Member 'shim' $Shims
        }
        
        Write-Config $config $ProjectName
    }

    $Input
}

function Remove-Shims {
 	param (
		[parameter(Position = 0, Mandatory = $true)]
		[string] $ShimsString,

        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)		
    
	if (Test-Config $ProjectName) {
        $shims = [regex]::split($ShimsString, ',|\s')
        $config = Read-Config $ProjectName

        if ($config.shim) {
            $shimNames = $config.shim | Get-Member -MemberType NoteProperty |% {$_.Name} | Where-Object {$shims -notcontains $_}
            $shim = $config.shim | Select -property $shimNames
            if ($shim -eq $null) { $shim = [pscustomobject]@{} }
            $Config | Add-Member 'shim' $shim -Force
        }
        
        Write-Config $config $ProjectName
    }

    $Input
}

function Add-ScalejsExtension {
 	param (
		[parameter(Position = 0, Mandatory = $true)]
		[string] $Extension,

        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)		

	if (Test-Config $ProjectName) {
        $config = Read-Config $ProjectName
        
        if (-not $config.scalejs) {
            $config | Add-Member 'scalejs' @{ extensions = @($Extension) }
        } else { 
            if ($config.scalejs.extensions -eq $null) {
                $config.scalejs | Add-Member 'extensions' @($Extension) 
            } else {
                $config.scalejs.extensions += $Extension
            }
        }

        Write-Config $config $ProjectName
    }

    $Input
}

function Remove-ScalejsExtension {
 	param (
		[parameter(Position = 0, Mandatory = $true)]
		[string] $Extension,

        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)		
	
	if (Test-Config $ProjectName) {
        $config = Read-Config $ProjectName
        
        $extensions = $config.scalejs.extensions
        if ($extensions) {
            $extensions = @() + ($extensions |? {$_ -ne $Extension})
            $config.scalejs | Add-Member 'extensions' $extensions -Force
        }

        Write-Config $config $ProjectName
    }

    $Input
}

function Get-ScalejsProjectType {
 	param (
        [parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string] $ProjectName
	)		
	
	$project = Resolve-ProjectName $ProjectName
	$projectPath = $project.FullName
	$projectType = select-string -Path $projectPath -Pattern "<ScalejsProjectType>(\w+)</ScalejsProjectType>" | %{$_.Matches.Groups[1].Value}

	return $projectType
}

function Register-ScalejsSolution {
	# [System.IO.File]::AppendAllText("c:\temp\dte.out", "`nCalled Set-Dte " + $dte)
	if (-not ("Dte" -as [type])) {
		try {
			[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nadding type Dte")
			Add-Type -ReferencedAssemblies @("EnvDTE") -TypeDefinition @" 
using System;
using EnvDTE;

public class Dte {
	private DTE dte;
	private Events dteEvents;
	private DocumentEvents documentEvents;
	
	public event Action<Document> DocumentSaved = delegate {};

	public Dte(object dte) {
		//System.IO.File.AppendAllText(@"c:\temp\dte.out", "--->dte creating");
		this.dte = (DTE)dte;
		this.dteEvents = this.dte.Events;
		this.documentEvents = this.dteEvents.DocumentEvents;
		this.documentEvents.DocumentSaved += OnDocumentSaved;
		//System.IO.File.AppendAllText(@"c:\temp\dte.out", "--->dte created");
	}
	
	private void OnDocumentSaved(Document document) {
		System.IO.File.AppendAllText(@"c:\temp\dte.out", "--->before document saved");
		DocumentSaved(document);
		System.IO.File.AppendAllText(@"c:\temp\dte.out", "--->after document saved");
	}
	
	public void Dispose() {
		this.documentEvents.DocumentSaved -= OnDocumentSaved;
		this.documentEvents = null;
		this.dteEvents = null;
		this.dte = null;
	}
}
"@
		} catch [System.Exception] {
			[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nexception to create type Dte " + $Error[0].Exception + $Error[0].Exception.InnerException + $_.Exception)
		}
	}
	$global:dteWrapper = New-Object "Dte" -ArgumentList @($dte)
	# [System.IO.File]::AppendAllText("c:\temp\dte.out", "`ndte wrapper = $dteWrapper, dte = $dte")
	try {
		$global:documentSavedRegistration = Register-ObjectEvent -InputObject $dteWrapper -EventName DocumentSaved -Action { 
			[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nCalled on save '$($Args.FullName)'")
		}
	} catch {
			[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nexception registering event " + $Error[0].Exception + $Error[0].Exception.InnerException + $_.Exception)
	}
}

function Unregister-ScalejsSolution {
	[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nUnregister-ScalejsSolution is called '$documentSavedRegistration'")
	if (Test-Path variable:global:documentSavedRegistration) {
		[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nUnregister event $documentSavedRegistration")
		Unregister-Event $documentSavedRegistration.Id
	}
	if (Test-Path variable:global:dteWrapper) {
		[System.IO.File]::AppendAllText("c:\temp\dte.out", "`nDispose $dteWrapper")
		$dteWrapper.Dispose()
	}
}

Export-ModuleMember *
