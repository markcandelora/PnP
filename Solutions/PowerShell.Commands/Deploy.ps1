Param(
	[string]$cfg = "Install.xml",
	[switch]$noExecute
)

#region ########## global variables ###########
#-------------------------------------------
# Custom Types
#-------------------------------------------
Add-Type "
    public class StackEntry {
        public int stepNumber;
        public string stepName;
        public string installFile;
        public System.Collections.Generic.Dictionary<string, object> variables;
        public bool loggingEnabled;
        public bool collectUls;
        public System.DateTime startTime;
    }";

#-------------------------------------------
# Global Variables
#-------------------------------------------
[string]$global:scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent;
[String[]]$global:scriptArgs = $args;
[bool]$global:loggingEnabled = $true;
[bool]$global:collectUls = $true;
[System.Collections.Generic.Dictionary[string, object]]$global:variables = `
    New-Object "System.Collections.Generic.Dictionary[string, object]";
[DateTime]$global:startTime = Get-Date;
[System.Collections.Stack]$global:installStack = New-Object "System.Collections.Stack";
#endregion

#region ########## PS Snapins / Utility ###########
function Ensure-PSSnapin([string]$snapinName) {
    #register the snapin if it's not already
    $registered = (Get-PSSnapin $snapinName -Registered -ErrorAction "SilentlyContinue") -ne $null;
    if (!$registered) {
        Write-Host "Registering snapin: $snapinName ...";
        $file = @(Get-ChildItem -Recurse -Path "$($env:SystemRoot)\assembly\GAC_MSIL" "$($snapinName).dll")[0];
        $exe = @(Get-ChildItem -Recurse -Path $env:SystemRoot "installutil.exe")[0];
		try {
        	& $exe.FullName $file.FullName;
		} catch {
			Write-Error "Error registering snapin";
			Write-Error $_.Exception.Message;
		}
    }

    #add the snapin if it hasn't been added
    $added = (Get-PSSnapin $snapinName -ErrorAction "SilentlyContinue") -ne $null;
    if (!$added) {
        Write-Host "Adding snapin: $snapinName ...";
        Add-PSSnapin $snapinName;
    }
}

function Reload-PSSnapin([string]$snapinName) {
    #add the snapin if it hasn't been added
    $added = (Get-PSSnapin $snapinName -ErrorAction "SilentlyContinue") -ne $null;
    if ($added) {
        Write-Host "Removing snapin: $snapinName ...";
        Remove-PSSnapin $snapinName;
    }
	Ensure-PSSnapin $snapinName;
}

function Ensure-Module([string]$moduleName) {
	$loaded = (Get-Module -Name $moduleName) -ne $null;
	if (!$loaded) {
		Write-Host "Importing module $moduleName";
		Import-Module -Name $moduleName;
	}
}

function Ensure-SPO() {
	Ensure-Module "OfficeDevPnP.PowerShell.Commands";
}

function Invoke-NewProcess($expression, $credentials, [switch]$elevate) {
    $returnValue = $null;

	#From some testing I've done, the EncodedCommand parameter can't be too long - otherwise it blows up.
	#Using PowerShell files to execute commands...
	#temp directory must be accessible to both users...
	$tempDirectory = "c:\temp";
	$tempFilePath1 = Join-Path -Path $tempDirectory    -ChildPath "tmp-invoke-newprocess-elevate.ps1";
	$tempFilePath2 = Join-Path -Path $tempDirectory    -ChildPath "tmp-invoke-newprocess-creds.ps1";
	$tempFilePath3 = Join-Path -Path $tempDirectory    -ChildPath "tmp-invoke-newprocess.ps1";
	#$outFilePath =   Join-Path -Path $global:scriptDir -ChildPath "out-invoke-newprocess.txt";
	#$errFilePath =   Join-Path -Path $global:scriptDir -ChildPath "err-invoke-newprocess.txt";
	if ($elevate) {
        Out-File -InputObject "`$ErrorActionPreference = 'Stop'; $expression" -FilePath $tempFilePath1;
        $expression = "Start-Process -FilePath `"powershell.exe`" -ArgumentList `"-ExecutionPolicy Unrestricted -File ```"$tempFilePath1```"`" -Wait -Verb Runas;";
	}
	if ($credentials) {
        Out-File -InputObject "`$ErrorActionPreference = 'Stop'; $expression" -FilePath $tempFilePath2;
        $expression = "Start-Job -FilePath '$tempFilePath2' -Credential $credentials | Wait-Job | Receive-Job | Out-Null;";
	}
	if (!($elevate -or $credentials)) {
        Out-File -InputObject "`$ErrorActionPreference = 'Stop'; $expression" -FilePath $tempFilePath3;
        $expression = "Start-Job -FilePath '$tempFilePath3' | Wait-Job | Receive-Job | Out-Null;";
	}
	
	try {
		Invoke-Expression $expression;
	} finally {
		Start-Sleep -Seconds 1;
		Remove-Item $tempFilePath1 -ErrorAction SilentlyContinue;
		Remove-Item $tempFilePath2 -ErrorAction SilentlyContinue;
		Remove-Item $tempFilePath3 -ErrorAction SilentlyContinue;
	}
}

function Safe-Run($codeBlock, [ref]$success = [ref]$false, [ref]$err = [ref]$null) {
	$safeReturnValue = $null;
	$success.Value = $false;

    trap { $success.Value = $false; $err.Value = $_; continue; }
    try {
        $safeReturnValue = & $codeBlock;
		$success.Value = $?;
    } catch {
		$err.Value = $_;
		$success.Value = $false;
    }

	return $safeReturnValue;
}

function Try-Rerun($cmd, $successCheck, $failureMessage, [int]$maxIterations, [int]$maxSeconds, [switch]$doNotThrowOnError) {
	$i = 0;
	$success = $false;
	do {
		$i++;
		
		Write-Host "trying..." -noNewLine -noIndent:$tryagain;
		[bool]$s = $false;
		$err = $null;
		Safe-Run $cmd ([ref]$s) ([ref]$err) | Out-Null;
		
		if ($err) {
			Write-Host "error executing command.";
			if (!$doNotThrowOnError) {
				Write-Exception $err;
			} else {
				throw $err;
			}
		} else {
			if ($maxSeconds) {
				#for async operations, wait a certain period of time for the command to complete...
				$keepWaiting = $true;
				$t = 0;
				$sleepTime = $maxSeconds / 30.0;
				while ($keepWaiting) {
					Write-Host "." -noNewline -noIndent;
					Start-Sleep $sleepTime;
					$t += $sleepTime;
					$success = &$successCheck;
					$keepWaiting = !$success;
					$keepWaiting = $keepWaiting -and $t -lt $maxSeconds;
				}
			}
			Write-Host "." -noIndent;
		}
		$success = &$successCheck;
		$tryagain = (!$success) -and ($i -lt $maxIterations);

		if ($tryagain) { Write-Host "re" -noNewline; }
	} while ( $tryagain )
	
	if (!$success) {
		throw $failureMessage;
	}
}
#endregion

#region ########## Stack functions ###########
function Push-InstallStack([string]$installFile) {
    [StackEntry]$entry = New-Object "StackEntry";
    $entry.installFile = $installFile;
    $entry.collectUls = $global:collectUls;
    $entry.loggingEnabled = $global:loggingEnabled;
    $entry.startTime = $global:startTime;
    $entry.variables = New-Object "System.Collections.Generic.Dictionary[string, object]" $global:variables;
    $global:installStack.Push($entry);
}

function Pop-InstallStack() {
    [StackEntry]$returnValue = $global:installStack.Pop();
    $global:collectUls = $returnValue.collectUls;
    $global:loggingEnabled = $returnValue.loggingEnabled;
    $global:startTime = $returnValue.startTime;
    $global:variables = $returnValue.variables;
    return $returnValue;
}

function Peek-InstallStack([switch]$stepNumber, [switch]$stepName) {
    if ($stepNumber) {
        [System.Text.StringBuilder]$returnValue = New-Object "System.Text.StringBuilder";
        $global:installStack | % {
            if ($_) {
                if ($returnValue.Length) { $returnValue.Insert(0, ".") | Out-Null; }
                $returnValue.Insert(0, "$($_.stepNumber)") | Out-Null;
            }
        }
        return $returnValue.ToString();
    } elseif ($stepName) {
        [System.Text.StringBuilder]$returnValue = New-Object "System.Text.StringBuilder";
        $global:installStack | % {
            if ($_) {
                if ($returnValue.Length) { $returnValue.Insert(0, "/") | Out-Null; }
                $returnValue.Insert(0, "$($_.installFile)") | Out-Null;
            }
        }
        $returnValue.Append("/$($global:installStack.Peek().stepName)") | Out-Null;
        return $returnValue.ToString();
    } else {
        return $global:installStack.Peek();
    }
}

function Set-InstallStep([string]$name, [int]$number) {
    $stackEntry = Peek-InstallStack;
    if ($name) {
        $stackEntry.stepName = $name;
    }
    if ($number) {
        $stackEntry.stepNumber = $number;
    }
}

function Get-InstallStep([string]$formatString = 'Step {0}: {1}') {
    return $formatString -f (Peek-InstallStack -stepNumber),(Peek-InstallStack -stepName);
}
#endregion

#region ########## Print functions ###########
function Write-Host([string]$message, [string]$foregroundColor, [int]$adjustment = 1, [switch]$noNewLine, [switch]$noIndent) {
	if (!$noIndent) {
	    [int]$level = ((Get-PSCallStack).Count) - $adjustment;
	    1..$level | % { $indent += "  "; }
	}
    if ($ForegroundColor) {
        Microsoft.PowerShell.Utility\Write-Host "$indent$message" -ForegroundColor $foregroundColor -NoNewLine:$noNewLine;
    } else {
        Microsoft.PowerShell.Utility\Write-Host "$indent$message" -NoNewLine:$noNewLine;
    }
}

function Write-Ok([string]$message, [switch]$noNewLine, [switch]$noIndent) {
    Write-Host $message -ForegroundColor "Green" -adjustment 1 -noNewLine:$noNewLine -noIndent:$noIndent;
}

function Write-Error([string]$message, [switch]$noNewLine, [switch]$noIndent) {
    Write-Host $message -ForegroundColor "Red" -adjustment 1 -noNewLine:$noNewLine -noIndent:$noIndent;
}

function Write-Warning([string]$message, [switch]$noNewLine, [switch]$noIndent) {
    Write-Host $message -ForegroundColor "DarkRed" -adjustment 1 -noNewLine:$noNewLine -noIndent:$noIndent;
}

function Write-Exception($err) {
	Write-Host "";
    $orig = $host.UI.RawUI.ForegroundColor;
	try {
	    $host.UI.RawUI.ForegroundColor = "Red";

	    $err | Out-Host;
		Write-StackTrace $err;

	    [Exception]$ex = $err.Exception;
	    if ($ex -is [System.Management.Automation.RemoteException]) {
	        $ex = $ex.SerializedRemoteException;
	    }
	    
		Write-Host "";
	    Write-Host ".NET Stack trace:" -ForegroundColor "Red" -noIndent;
	    Write-StackTrace $ex;
	} finally {
    	$host.UI.RawUI.ForegroundColor = $orig;
	}
}

function Write-StackTrace($e) {
	if ($e -is [System.Management.Automation.ErrorRecord]) {
		Write-Host $e.ScriptStackTrace -Foreground "Red" -noIndent;
	} elseif ($e -is [System.Exception]) {
	    if (!$e.GetType().FullName -notlike "System.Management.Automation.*") {
	        Write-Host $e.StackTrace -Foreground "Red" -noIndent;
	    }

	    if ($e.InnerException -and $e.InnerException.StackTrace) {
	        Write-StackTrace $e.InnerException;
	    }
	}
}
#endregion


#-------------------------------------------
# Deployment Functions
#-------------------------------------------
#region ################ Web Deploy ################
function CreateWeb([System.Xml.XmlElement]$config) {
	$title = Get-Value $config.Title;
	$url = Get-Value $config.Url;
	$description = Get-Value $config.Description;
	$locale = Get-Value $config.Locale -defaultValue 1033;
	$template = Get-Value $config.Template;
	Create-Web $title $url $description $locale $template;
}
function Create-Web($title, $url, $description, $locale, $template) {
	Ensure-SPO;
	Write-Host "Starting web creation";
    $serverRelativeUrl = Split-Url $url -Path;
	$web = Get-SPOWeb $serverRelativeUrl -ErrorAction SilentlyContinue;
	if (!$web) {
		Write-Host "Creating web $title at $url";
        $parent = "/" + (Split-Url $serverRelativeUrl -parent);
        $leaf = Split-Url $serverRelativeUrl -leaf;
		$web = New-SPOWeb -Title $title -Web $parent -Url $leaf -Description $description -Locale $locale -Template $template;
	} else {
		Write-Host "Web already exists at $url";
	}
	Write-Ok "Completed web creation";
}
function DeleteWeb([System.Xml.XmlElement]$config) {
	$url = Get-Value $config.Url;
	Delete-Web $url | Out-Null;
}
function Delete-Web($url) {
	Ensure-SPO;
	Write-Host "Starting web deletion";
    $serverRelativeUrl = Split-Url $url -Path;
	$web = Get-SPOWeb $serverRelativeUrl -ErrorAction SilentlyContinue;
	if ($web) {
		Write-Host "Deleting web $title at $url";
		$web.DeleteObject();
        (Get-SPOContext)
	} else {
		Write-Host "No web exists at $url";
	}
	Write-Ok "Completed web deletion";
}
function ApplyWebTemplate([System.Xml.XmlElement]$config) {
    $url = Get-Value $config.Url;
    $templatePath = Get-Value $config.TemplatePath;
    Apply-WebTemplate $url $templatePath;
}
function Apply-WebTemplate([string]$url, [string]$templatePath) {
    Write-Host "Applying web template";
    $serverRelativeUrl = Split-Url $url -Path;
    $fullTemplatePath = Get-ScriptPath $templatePath;
    Apply-SPOProvisioningTemplate -Web $serverRelativeUrl -Path $fullTemplatePath;
    Write-Ok "Completed applying web template";
}
#endregion

#region ############# File Deploy ################
function AddFiles([System.Xml.XmlElement]$config) {
}
function Add-Files([string]$webUrl, [string]$sourcePath, [string]$targetPath) {
    Write-Host "Adding files to $targetPath";
    $sourceFullPath = Get-ScriptPath $sourcePath;
    $sourceObjects = Get-ChildItem $sourceFullPath -Recurse;
    foreach ($srcObj in $sourceObjects) {
        $relativePath = $srcObj.FullName -replace $sourceFullPath,"";
        Write-Host "Uploading $relativePath";

        $targetFullPath = Join-Url $webUrl,$targetPath,$srcRelativePath;
        $targetServerRelativePath = Split-Url $targetFullPath -Path;
        $targetParent = Split-Url $targetServerRelativePath -Parent;
        $targetLeaf = Split-Url $targetServerRelativePath -Leaf;
        if ($srcObj -is [System.IO.FileInfo]) {
            Add-SPOFile -Web $webUrl -Folder $targetParent -Path $srcObj.FullName -Approve -Publish;
        } else {
            Add-SPOFolder -Web $webUrl -Folder $targetParent -Name $leaf;
        }
    }
    Write-Ok "Completed adding files";
}
#endregion

#region ############# Lists ################
function DeleteList([System.Xml.XmlElement]$config) {
    $webUrl = Get-Value $config.WebUrl;
    $listUrl = Get-Value $config.ListUrl;
    Delete-List $webUrl $listUrl;
}
function Delete-List($webUrl, $listUrl) {
    $serverRelativeUrl = Split-Url $webUrl -path;
    $list = Get-SPOList -Web $serverRelativeUrl -Identity $listUrl -ErrorAction SilentlyContinue;
    if ($list) {
        Write-Host "Removing list at $listUrl";
        Remove-SPOList -Web $serverRelativeUrl -Identity $listUrl -Confirm:$false;
    } else {
        Write-Host "No list exists at $listUrl";
    }
    Write-Ok "List deleted.";
}
#endregion

#region ############# Web Parts ################
function AddWebPart([System.Xml.XmlElement]$config) {
    $webUrl = Get-Value $config.Weburl;
    $pageUrl = Get-Value $config.PageUrl;
    $webPartXml = Get-Value $config.InnerXml;
    $zoneId = Get-Value $config.ZoneId;
    $zoneIndex = Get-Value $config.ZoneIndex;
    $column = Get-Value $config.Column;
    $row = Get-Value $config.Row;
    Add-WebPart $webUrl $pageUrl $webPartXml $zoneId $zoneIndex $column $row;
}
function Add-WebPart([string]$webUrl, [string]$pageUrl, [string]$webPartXml, [string]$zoneId, [int]$zoneIndex, [int]$column, [int]$row) {
    Write-Host "Adding web part to $webUrl";
    $serverRelativeWebUrl = Split-Url $webUrl -path;
    $serverRelativePageUrl = Split-Url (Join-Url $webUrl,$pageUrl) -Path;
    $props = ([Xml]$webPartXml).webParts.webPart.data.properties.property;
    $title = ($props | ? { $_.name -eq "Title" })."#Text";
    
    $wps = Get-SPOWebPart -Web $serverRelativeWebUrl -PageUrl $serverRelativePageUrl;
    $wp = $wps | ? { $_.WebPart.Properties.FieldValues["Title"] -eq $wpTitle; };
    
    if (!$wp) {
        if ($zoneId) {
            Add-SPOWebPartToWebPartPage -Web $serverRelativeWebUrl -PageUrl $serverRelativePageUrl -Xml $webPartXml -ZoneId $zoneId -ZoneIndex $zoneIndex;
        } else {
            Add-SPOWebPartToWikiPage -Web $serverRelativeWebUrl -PageUrl $serverRelativePageUrl -Xml $webPartXml -Column $column -Row $row;
        }
    } else {
        Write-Host "Web Part $wpTitle already added to page.";
    }
    Write-Ok "Completed adding web part to page";
}
function RemoveWebPart([System.Xml.XmlElement]$config) {
    $webUrl = Get-Value $config.WebUrl;
    $pageUrl = Get-Value $config.PageUrl;
    $title = Get-Value $config.Title;
    Remove-WebPart $webUrl $pageUrl $title;
}
function Remove-WebPart([string]$webUrl, [string]$pageUrl, [string]$title) {
    Write-Host "Removing web part $title at $pageUrl";
    $serverRelativeWebUrl = Split-Url $webUrl -path;
    $serverRelativePageUrl = Split-Url (Join-Url $webUrl,$pageUrl) -Path;
    $props = ([Xml]$webPartXml).webParts.webPart.data.properties.property;
    $title = ($props | ? { $_.name -eq "Title" })."#Text";
    
    $wps = Get-SPOWebPart -Web $serverRelativeWebUrl -PageUrl $serverRelativePageUrl;
    $wp = $wps | ? { $_.WebPart.Properties.FieldValues["Title"] -eq $wpTitle; };

    if ($wp) {
        Remove-SPOWebPart -Web $serverRelativeWebUrl -PageUrl $serverRelativePageUrl -Name $title;
    } else {
        Write-Host "Web part $title does not exist on page";
    }
    Write-Ok "Done removing web part";
}
#endregion

#region ############# Connect to Tenant ################
function Connect([System.Xml.XmlElement]$config) {
	$url = Get-Value $config.Url;
	$credentials = Get-Value $config.Credentials;
	Connect-SharePoint $url $credentials;
}
function Connect-SharePoint($url, $credentials) {
	Connect-SPOnline -Url $url -Credentials $credentials;
	Write-Ok "Login complete";
}
#endregion

#region ############# Testing & Validation ################
function RequestUrl([int]$maxTries = 3, [int]$wait = 2, [string]$domain = "", [string]$userName = "", [string]$password = "", [string[]]$urls) {
    $client = New-Object System.Net.WebClient;
    if ($userName -and $domain -and $password) {
        $client.Credentials = New-Object system.Net.NetworkCredential $userName,$password,$domain
    } else {
        $client.UseDefaultCredentials = $true;
    }

    $urls | % {
        $url = Get-Value $_;
        $tries = 0;
        $done = $false;
        $ex = $null;
        while ($tries -lt $maxTries -and !$done) {
            try {
                $response = $client.DownloadString($url);
				ValidateResponse $response;
				$done = $true;
				Write-OK "Completed request to $url";
            } catch [Exception] {
                $ex = $_;
                $tries++;
                Write-Host "Request to $url failed: $($ex.Exception.Message)";
                Start-Sleep -Seconds $wait;
            }
        }
        if (!$done) {
            Stop-Install "Web request failed." $ex.Exception;
        }
    }
}

function ValidateResponse([string]$response) {
    $errorExpression = New-Object Regex "(?<=<span id=`"ctl00_PlaceHolderMain_LabelMessage`">)[^<]*(?=</span>)";
	if ($response -match "<title>\s*Error\s*</title>") {
		$errMsg = $errorExpression.Match($response).Value;
		throw (New-Object Exception $errMsg);
	}
}

function WebRequest([System.Xml.XmlElement]$config) {
    $maxTries = Get-Value $config.Retries 5;
    $wait = Get-Value $config.RetryDelay 5;
    $domain = Get-Value $config.Domain;
    $userName = Get-Value $config.UserName;
    $password = Get-Value $config.Password;
    
    $errorExpression = New-Object Regex "(?<=<span id=`"ctl00_PlaceHolderMain_LabelMessage`">)[^<]*(?=</span>)";
    $client = New-Object System.Net.WebClient;
    if ($userName -and $domain -and $password) {
        $client.Credentials = New-Object system.Net.NetworkCredential $userName,$password,$domain
    } else {
        $client.UseDefaultCredentials = $true;
    }
    
    $config.Page | % {
        $url = Get-Value $_;
        $tries = 0;
        $done = $false;
        $ex = $null;
        while ($tries -lt $maxTries -and !$done) {
            try {
                $response = $client.DownloadString($url);
                if ($response -match "<title>\s*Error\s*</title>") {
                    $errMsg = $errorExpression.Match($response).Value;
                    throw (New-Object Exception $errMsg);
                } else {
                    Write-OK "Completed request to $url";
                    $done = $true;
                }
            } catch [Exception] {
                $ex = $_;
                $tries++;
                Write-Host "Request to $url failed: $($ex.Exception.Message)";
                Start-Sleep -Seconds $wait;
            }
        }
        if (!$done) {
            Stop-Install "Web request failed." $ex.Exception;
        }
    }
}
#endregion

#region ############ Custom Actions & Scripts #############
function Pause([System.Xml.XmlElement]$config) {
	$msg = Get-Value $config.Message;
	$seconds = [int](Get-Value $config.Seconds);
	Write-Host $msg;
	if ($seconds) {
		Start-Sleep -Seconds $seconds;
	} else {
		Read-Host "Press any key to continue.";
	}
}

function CustomAction([System.Xml.XmlElement]$config) {
    $scriptPath = Get-Value $config.ScriptPath;
    $script = Get-Value $config.InnerText;

    if ($scriptPath) {
	    Write-Host "Executing custom action '$scriptPath'...";
        if (!($scriptPath -contains '\')) {
            $scriptPath = Join-Path $scriptDir $scriptPath;
        }
        $script = Get-Value ([System.IO.File]::ReadAllText($scriptPath))
    } else {
	    Write-Host "Executing custom action...";
	}

    $paramsBuilder = New-Object "System.Text.StringBuilder";
    $config.Parameter | % {
        if ($_) {
            $paramName = Get-Value $_.Name;
            $paramValue = Get-Value $_.Value;
            if ($paramValue) {
                $paramsBuilder.Append((" -$paramName '$paramValue'")) | Out-Null;
            } else {
                $paramsBuilder.Append((" -$paramName")) | Out-Null;
            }
        }
    }
    $params = $paramsBuilder.ToString();
    $codeBlock = Invoke-Expression "{ $script }";
    Invoke-Expression "& `$codeBlock $params;";

    Write-Ok "Custom action completed";
}

function LoadLibrary([System.Xml.XmlElement]$config) {
    $libraryName = Get-Value $config.Library;
    Write-Host "Loading Library '$libraryName'";
    $libraryPath = Join-Path $scriptDir $libraryName;
    Invoke-Expression ". $libraryPath";
    Write-Ok "Library loaded: '$libraryPath'";
}

function Install([System.Xml.XmlElement]$config) {
    $file = Get-Value $config.ConfigFile;
    
    $currentLogging = $global:loggingEnabled;
    $currentUls = $global:collectUls;
    
    Write-Host "";
    Write-Host "Starting install $file";
    Start-Install $file $false;
    Write-Ok "Completed install $file";
    Write-Host "";
}
#endregion

#-------------------------------------------
# Utility Functions
#-------------------------------------------
#region ############ Remote execution #############
function Test-ServerConnection ($server) {
    Write-Host "Testing connection (via Ping) to `"$server`"..." -NoNewline;
    try {
		Test-Connection -ComputerName $server -Count 1 | Out-Null;
		Write-Ok "Success." -noIndent;
	} catch {
        Write-Error "Connection test failed." -noIndent;
        Write-Error "Check that `"$server`":";
        Write-Error "  - Is online";
        Write-Error "  - Has the required Windows Firewall exceptions set (or turned off)";
        Write-Error "  - Has a valid DNS entry for $server";
		Stop-Install "Can not connect to remote server '$server'" $_;
    }
}

function Enable-RemoteSession ($server, $credentials) {
	$psExePath = Ensure-PSExec;
    Enable-WSManCredSSP -Role Client -Force -DelegateComputer $server | Out-Null;
	Test-ServerConnection $server;
	
	$localWorkspace = Split-Path -Path $psExePath -Parent;
	Create-NetworkShare -shareName "psinstall" -localPath $localWorkspace -user "$env:USERDOMAIN\$env:USERNAME" -perms "CHANGE"; 
	$remoteWorkspace = "\\$env:COMPUTERNAME\psinstall";
	$userName = $credentials.UserName;
	$password = Decrypt-SecureString $credentials.Password;
    $configureTargetScript = Join-Path -Path $remoteWorkspace -ChildPath "config.ps1";
	
	if (!(Get-Item $configureTargetScript -ErrorAction SilentlyContinue)) {
		$fileContents = @"
# Configures the server for WinRM and WSManCredSSP
`$winRM = Get-Service -Name winrm;
if (`$winRM.Status -ne "Running") { Start-Service -Name "winrm"; };
Set-ExecutionPolicy Bypass -Force;
Enable-PSRemoting -Force;
Enable-WSManCredSSP -Role Server -Force | Out-Null;
# Increase the local memory limit to 1 GB
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 1024;
#Get out of this PowerShell process
Stop-Process -Id `$PID -Force;
"@;
		Out-File -InputObject $fileContents -FilePath $configureTargetScript;
	}

	Write-Host "Updating PowerShell execution policy on `"$server`" via PsExec...";
    Start-Process -FilePath "$psExePath" `
                  -ArgumentList "/acceptEula \\$server -h powershell.exe -Command `"Set-ExecutionPolicy Bypass -Force ; Stop-Process -Id `$PID`"" `
                  -Wait `
				  -NoNewWindow;
    # Another way to exit powershell when running over PsExec from http://www.leeholmes.com/blog/2007/10/02/using-powershell-and-PsExec-to-invoke-expressions-on-remote-computers/
    # PsExec \\server cmd /c "echo . | powershell {command}"
    Write-Host "Enabling PowerShell remoting on `"$server`" via PsExec...";
    Start-Process -FilePath "$psExePath" `
                  -ArgumentList "/acceptEula \\$server -u $userName -p $password -h powershell.exe -Command `"$configureTargetScript`"" `
                  -Wait `
				  -NoNewWindow;

	Delete-NetworkShare -ShareName "psinstall"; 
}

function Invoke-RemoteCommand ($server, $credentials, $command, $argumentList) {
	$returnValue = $null;
	$userName = $credentials.UserName;
	$password = Decrypt-SecureString $credentials.Password;

	Write-Host "Running command on $server...";
	$session = New-PSSession -Name "psinstall-$server" -Authentication Credssp -Credential $credentials -ComputerName $server;
	Write-Debug "Created session `"$($session.Name)`"";
	try {
	    $returnValue = Invoke-Command -ScriptBlock $command -ArgumentList $argumentList -Session $session;
	} finally {
	    Write-Debug "Removing session `"$($session.Name)`"...";
	    Remove-PSSession $session;
	}
	return $returnValue;
}

function Ensure-PSExec() {
	$returnValue = Join-Path -Path $global:scriptDir -ChildPath "PsExec.exe";
    if (!(Get-Item ($returnValue) -ErrorAction SilentlyContinue)) {
        Write-Host "PsExec.exe not found; downloading...";
        $psExecUrl = "http://live.sysinternals.com/PsExec.exe"
        Import-Module BitsTransfer | Out-Null
        Start-BitsTransfer -Source $psExecUrl -Destination $returnValue -DisplayName "Downloading Sysinternals PsExec..." -Priority Foreground -Description "From $psExecUrl...";
    }
	return $returnValue;
}

function Delete-NetworkShare([string]$shareName) {
    Write-Host "Removing network share $pathToShare";
	if ((Get-Item "\\$env:COMPUTERNAME\$shareName" -ErrorAction SilentlyContinue)) {
		Start-Process -FilePath net.exe -ArgumentList "share $shareName /DELETE" -Wait;
	}
	Write-OK "Share deleted.";
}

function Create-NetworkShare([string]$shareName, [string]$localPath, [string]$user, [string]$perms) {
	if (!("READ","CHANGE","FULL") -contains $perms) { Stop-Install "Invalid value $perms for parameter perms - must be one of: READ, CHANGE, or FULL"; }
	if (!(Get-Item $localPath -ErrorAction SilentlyContinue)) { Stop-Install "Path $localPath does not exist."; }

	$pathToShare = """$shareName=$localPath""";
    Write-Host "Creating network share $pathToShare";
	if (!(Get-Item "\\$env:COMPUTERNAME\$shareName" -ErrorAction SilentlyContinue)) {
    	Start-Process -FilePath net.exe -ArgumentList "share $pathToShare `"/GRANT:$user,$perms`"" -Wait;
	}
	Write-Ok "Share \\$env:COMPUTERNAME\$shareName created.";
}

#endregion

#region ########## Variables ###########
function SetVariables([System.Xml.XmlElement]$config) {
    $overwrite = Get-BoolValue $config.Overwrite;
    $config.ChildNodes | % {
        if ($_ -is [System.Xml.XmlElement]) {
			if ($_.Name -eq "Prompt") {
	            SetVariablePrompt $_ -overwrite:$overwrite;
			} elseif ($_.Name -eq "Function") {
	            SetVariablefunction $_ -overwrite:$overwrite;
			} elseif ($_.Name -eq "Script") {
	            SetVariableScript $_ -overwrite:$overwrite;
			} elseif ($_.Name -eq "Credential") {
	            SetVariableCredential $_ -overwrite:$overwrite;
			} elseif ($_.Name -eq "Environment") {
	            SetVariableEnvironment $_ -overwrite:$overwrite;
			} else {
	            SetVariable $_ -overwrite:$overwrite;
			}
        }
    }
}

function SetVariablePrompt([System.Xml.XmlElement]$config, [bool]$overwrite = $false) {
    $title = Get-Value $config.Title;
    $message = Get-Value $config.Message;
    $params = New-Object "System.Collections.Generic.List[object]";
    $config.Param | % {
        if ($_) {
            $value = Get-Value $_.Name;
            $set = $overwrite -OR
                   (Get-ScriptVariable $value -returnNull) -EQ $null;
            if ($set) {
                $params.Add($value);
            } else {
                Write-Host "Inheriting variable '$value' $(Get-ScriptVariable $value -returnNull)";
            }
        }
    }
	if ($params.Length -gt 0) {
    $value = PromptUser $title $message $params.ToArray();
	}
    $value.Keys | % {
        if ($_) {
            Set-ScriptVariable $_ $value[$_];
        }
    }
}

function SetVariableScript([System.Xml.XmlElement]$config, [bool]$overwrite = $false) {
    $name = $config.VariableName;
    $set = $overwrite -OR
           (Get-ScriptVariable $name -returnNull) -EQ $null;
    if ($set) {
        $script = $config.InnerText;
        $value = Invoke-Expression $script;
        Set-ScriptVariable $name $value;
    } else {
        Write-Host "Inheriting variable '$name' $(Get-ScriptVariable $name -returnNull)";
    }
}

function SetVariableFunction([System.Xml.XmlElement]$config, [bool]$overwrite = $false) {
    $name = $config.VariableName;
    $set = $overwrite -OR
           (Get-ScriptVariable $name -returnNull) -EQ $null;
    if ($set) {
        $functionName = $config.FunctionName;
        $params = New-Object "System.Text.StringBuilder";
        $config.Param | % {
            if ($_) {
                $paramName = $_.Name;
                $paramVal = Get-Value $_.InnerText;
                $param = " -$paramName '$(Get-Value $paramVal)'";
                $params.Append($param) | Out-Null;
            }
        }
        $value = Runfunction $functionName $params.ToString();
        Set-ScriptVariable $name $value;
    } else {
        Write-Host "Inheriting variable '$name' $(Get-ScriptVariable $name -returnNull)";
    }
}

function SetVariable([System.Xml.XmlElement]$config, [bool]$overwrite = $false) {
    $name = $config.VariableName;
    $set = $overwrite -OR
           (Get-ScriptVariable $name -returnNull) -EQ $null;
    if ($set) {
        $value = Get-Value $config.InnerText;
        Set-ScriptVariable $name $value;
    } else {
        Write-Host "Inheriting variable '$name' $(Get-ScriptVariable $name -returnNull)";
    }
}

function SetVariableEnvironment([System.Xml.XmlElement]$config, [bool]$overwrite = $false) {
    $name = $config.VariableName;
    $set = $overwrite -OR
           (Get-ScriptVariable $name -returnNull) -EQ $null;
    if ($set) {
        $env = Get-Value $config.EnvironmentVariable;
		$value = Get-EnvironmentVariable $env;
        Set-ScriptVariable $name $value;
    } else {
        Write-Host "Inheriting variable '$name' $(Get-ScriptVariable $name -returnNull)";
    }
}

function SetVariableCredential([System.Xml.XmlElement]$config, [bool]$overwrite = $false) {
    $name = $config.VariableName;
    $set = $overwrite -OR
           (Get-ScriptVariable $name -returnNull) -EQ $null;
    if ($set) {
        $userName = Get-Value $config.UserName;
		$password = Get-Value $config.Password;
		if ($userName -and $password) {
			$value = Create-Credential -userName $userName -password $password;
		} else {
			$value = Get-Credential -Credential $userName;
		}
        Set-ScriptVariable $name $value;
    } else {
        Write-Host "Inheriting variable '$name' $(Get-ScriptVariable $name -returnNull)";
    }
}

function RunFunction([string]$function, [string]$params) {
    Invoke-Expression "$function $params";
}

function PromptUser([string]$caption, [string]$message, [string[]]$variables) {
    $options = New-Object "System.Collections.Generic.List[System.Management.Automation.Host.FieldDescription]";
    $variables | % {
        $option = New-Object "System.Management.Automation.Host.FieldDescription" $_;
        $options.Add($option);
    }
    $result = $host.ui.Prompt($caption, $message, $options);
    return $result;
}

function Set-ScriptVariable([string]$name, [Object]$value) {
    $global:variables[$name] = $value;
    Write-Ok "Set variable '$name' = $value";
}

function Get-ScriptVariable([string]$expression, [switch]$returnNull) {
    if ($global:variables.ContainsKey($expression)) {
        return $global:variables[$expression];
    } elseif ($returnNull) {
        return $null;
    } else {
        return $expression;
    }
}

function Get-BoolValue($expression, $defaultValue = $false) {
    if ([bool]$expression) {
        return [bool]::Parse((Get-Value $expression));
    } else {
        return $defaultValue;
    }
}

function Get-Value($expression, $defaultValue) {
    $returnValue = $expression;
    if ($expression -is [string] -or $expression -eq $null) {
        if ($expression -match "(.\$\{[^}]*})|(\$\{[^}]*}.)") {
            $returnValue = Replace-Parameters $expression;
        } elseif ($expression -match "\$\{[^}]*}") {
            $param = [System.Text.RegularExpressions.Regex]::Match($expression, "(?<=\$\{)[^}]*(?=})").Value;
            $returnValue = Get-ScriptVariable $param;
        } elseif (!$expression) {
            $returnValue = $defaultValue;
        }
    }
    return $returnValue;
}

function Replace-Parameters($expression) {
    $returnValue = $expression;
    if ($expression -ne $null) {
        $regex = New-Object "System.Text.RegularExpressions.Regex" "\$\{(?<name>[^}]*)}";
        $matches = $regex.Matches($expression);
        foreach ($match in $matches) {
            $varExp = $match.Value;
            $varName = $match.Groups["name"];
            $val = Get-ScriptVariable($varName);
            $returnValue = $returnValue.Replace($varExp, $val);
        }
    }
    return $returnValue;
}

function Get-EnvironmentVariable([string]$name) {
    [Environment]::GetEnvironmentVariable($name);
}

function Read-Credential([System.Xml.XmlElement]$config) {
	$returnValue = Get-Value $config.Credentials;
	if ($config) {
		$userName = Get-Value $config.UserName;
		$password = Get-Value $config.Password;
		$passwordFile = Get-Value $config.PasswordFile;
		if (!$returnValue) { 
			$returnValue = Create-Credential $userName $password $passwordFile; 
		}
	}
	return $returnValue;
}
#endregion

#region ############ General Utilities #############
function Split-Url([string]$url, [switch]$parent, [switch]$base, [switch]$leaf, [switch]$path, [switch]$query) {
    $returnValue = "";
    if ($url -like "*://*") {
        $uri = New-Object Uri($url);
        if ($uri.Host) {
            $urihost = $uri.Scheme + [Uri]::SchemeDelimiter + $uri.Host;
        }
        $uriSegments = $uri.Segments;
        $uriQuery = $uri.Query;
    } else {
        $uriSegments = $url -split "/";
        if ($url -match "\?") {
            $uriQuery = $url -split "?" | Select-Object -Last 1;
        }
    }

    if ($parent) {
        $uriSegments = $uriSegments | Select-Object -First ($uriSegments.Length - 1);
        $uriPath = Join-Url $uriSegments;
        $returnValue = Join-Url $urihost, $uriPath;
    } elseif ($base) {
        $returnValue = $urihost;
    } elseif ($path) {
        $returnValue = "/" + (Join-Url $uriSegments);
    } elseif ($query) {
        $returnValue = $uriQuery;
    } elseif ($leaf) {
        $returnValue = $uriSegments | Select-Object -Last 1;
    }
    return $returnValue;
}

function Join-Url([string[]]$parts) {
    return ($parts  `
            | ? { $_ } `
            | % { $_.trim('/').trim() } `
            | ? { $_ } ) -join '/';
}

function Grant-FileSystemPermissions($path, $users, [System.Security.AccessControl.FileSystemRights]$rights) {
	$acl = Get-Acl -Path $path;
	foreach ($user in $users) {
		if ($user) {
			$rule = New-Object  System.Security.AccessControl.FileSystemAccessRule($user, $rights, "Allow");
			$acl.AddAccessRule($rule);
		}
	}
	Set-Acl -AclObject $acl -Path $path;
}

function RemoveIEEnhancedSecurity() {
    Write-Host "Disabling IE Enhanced Security...";
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name isinstalled -Value 0;
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name isinstalled -Value 0;

	Rundll32 iesetup.dll,IEHardenLMSettings,1,True
    Rundll32 iesetup.dll,IEHardenUser,1,True
    Rundll32 iesetup.dll,IEHardenAdmin,1,True

	if (Test-Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}") {
        Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}";
    }
    if (Test-Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}") {
        Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}";
    }

    #This doesn't always exist
    Remove-ItemProperty "HKCU:\SOFTWARE\Microsoft\Internet Explorer\Main" "First Home Page" -ErrorAction SilentlyContinue;
}

function Add-UserToGroup($domain, $userName, $groupName) {
    ([ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group").Add("WinNT://$domain/$userName") | Out-Null;
}

function Remove-UserFromGroup($domain, $userName, $groupName) {
    ([ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group").Remove("WinNT://$domain/$userName") | Out-Null;
}

function Assign-SSLCert($SSLHostHeader, $SSLPort, $SSLSiteName) {
    Import-WebAdministration;
    Write-Host "Assigning certificate to site `"https://$SSLHostHeader`:$SSLPort`"";
    # If our SSL host header is a FQDN (contains a dot), look for an existing wildcard cert
    if ($SSLHostHeader -like "*.*") {
        # Remove the host portion of the URL and the leading dot
        $splitSSLHostHeader = $SSLHostHeader  -split "\.";
        $topDomain = $SSLHostHeader.Substring($splitSSLHostHeader[0].Length + 1);
        # Create a new wildcard cert so we can potentially use it on other sites too
        if ($SSLHostHeader -like "*.$env:USERDNSDOMAIN") {$certCommonName = "*.$env:USERDNSDOMAIN"};
        elseif ($SSLHostHeader -like "*.$topDomain") {$certCommonName = "*.$topDomain"};
        Write-Host "Looking for existing `"$certCommonName`" wildcard certificate...";
        $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -like "CN=$certCommonName*"};
    } else {
        # Just create a cert that matches the SSL host header
        $certCommonName = $SSLHostHeader;
        Write-Host "Looking for existing `"$certCommonName`" certificate...";
        $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -eq "CN=$certCommonName"};
    }

    if (!$cert) {
        Write-Host "None found."
        # Get the actual location of makecert.exe in case we installed SharePoint in the non-default location
        $spInstallPath = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Office Server\$env:spVer.0").GetValue("InstallPath")
        $makeCert = "$spInstallPath\Tools\makecert.exe"
        if (Test-Path "$makeCert") {
            Write-Host "Creating new self-signed certificate $certCommonName..."
            Start-Process -NoNewWindow -Wait -FilePath "$makeCert" -ArgumentList "-r -pe -n `"CN=$certCommonName`" -eku 1.3.6.1.5.5.7.3.1 -ss My -sr localMachine -sky exchange -sp `"Microsoft RSA SChannel Cryptographic Provider`" -sy 12"
            $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -like "CN=``*$certCommonName"}
            if (!$cert) {$cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -eq "CN=$SSLHostHeader"}}
        } else {
            Write-Host "`"$makeCert`" not found."
            Write-Host "Looking for any machine-named certificates we can use..."
            # Select the first certificate with the most recent valid date
            $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -like "*$env:COMPUTERNAME"} | Sort-Object NotBefore -Desc | Select-Object -First 1
            if (!$cert) {
                Write-Host "None found, skipping certificate creation.";
            }
        }
    }
    if ($cert) {
        $certSubject = $cert.Subject;
        Write-Host "Certificate `"$certSubject`" found.";
        # Fix up the cert subject name to a file-friendly format
        $certSubjectName = $certSubject.Split(",")[0] -replace "CN=","" -replace "\*","wildcard";
        # Export our certificate to a file, then import it to the Trusted Root Certification Authorites store so we don't get nasty browser warnings
        # This will actually only work if the Subject and the host part of the URL are the same
        # Borrowed from https://www.orcsweb.com/blog/james/powershell-ing-on-windows-server-how-to-import-certificates-using-powershell/
        Write-Host "Exporting `"$certSubject`" to `"$certSubjectName.cer`"...";
        $cert.Export("Cert") | Set-Content -Path "$((Get-Item $env:TEMP).FullName)\$certSubjectName.cer" -Encoding byte;
        $pfx = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2;
        Write-Host "Importing `"$certSubjectName.cer`" to Local Machine\Root...";
        $pfx.Import("$((Get-Item $env:TEMP).FullName)\$certSubjectName.cer");
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root","LocalMachine");
        $store.Open("MaxAllowed");
        $store.Add($pfx);
        $store.Close();
        Write-Host "Assigning certificate `"$certSubject`" to SSL-enabled site...";
        #Set-Location IIS:\SslBindings -ErrorAction Inquire
        if (!(Get-Item IIS:\SslBindings\0.0.0.0!$SSLPort -ErrorAction SilentlyContinue)) {
            $cert | New-Item IIS:\SslBindings\0.0.0.0!$SSLPort -ErrorAction SilentlyContinue | Out-Null;
        }
        # Check if we have specified no host header
        if (!([string]::IsNullOrEmpty($webApp.UseHostHeader)) -and $webApp.UseHostHeader -eq $false) {
            Set-ItemProperty IIS:\Sites\$SSLSiteName -Name bindings -Value @{protocol="https";bindingInformation="*:$($SSLPort):"} -ErrorAction SilentlyContinue;
        } else {
			# Set the binding to the host header
            Set-ItemProperty IIS:\Sites\$SSLSiteName -Name bindings -Value @{protocol="https";bindingInformation="*:$($SSLPort):$($SSLHostHeader)"} -ErrorAction SilentlyContinue;
        }
        ## Set-WebBinding -Name $SSLSiteName -BindingInformation ":$($SSLPort):" -PropertyName Port -Value $SSLPort -PropertyName Protocol -Value https
        Write-Host "Certificate has been assigned to site `"https://$SSLHostHeader`:$SSLPort`"";
    } else {
		Write-Host "No certificates were found, and none could be created.";
	}
    $cert = $null;
}

function Decrypt-SecureString([System.Security.SecureString]$string) {
	$returnValue = "";
	$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($string);
	$returnValue = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr);
	[System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr);
	return $returnValue;
}

function Create-Credential([string]$userName, [string]$password, [string]$passwordFile) {
    if ($password) {
        $securePassword = (ConvertTo-SecureString -String $password -AsPlainText -Force);
    } elseif ($passwordFile) {
        $securePassword = Read-PasswordFile $passwordFile;
    } else {
        Stop-Install "password or passwordFile parameter is required";
    }
    $returnValue = New-Object "System.Management.Automation.PSCredential" @($userName,$securePassword);
    return $returnValue;
}

function Read-PasswordFile([string]$passwordFile) {
	##TODO: make this a secure file rather than just a plain-text file
	return Get-Content $passwordFile | ConvertTo-SecureString -AsPlainText;
}

function Ensure-Folder([string]$path) {
	$returnValue = Get-Item $path -ErrorAction SilentlyContinue;
	if (!$returnValue) {
		$returnValue = New-Item $path -ItemType Directory; 
	}
	return $returnValue;
}

function Get-ScriptPath([string]$path) {
    if ($path -like "*:/*") {
        $returnValue = $path;
    } else {
        $returnValue = Join-Path -Path $scriptDir -ChildPath $path;
    }
    return $returnValue;
}
#endregion

#region ############ Tracing functions #############
function Trace-Function([string]$expression) {
    $startTime = Get-Date;
    Write-Host "Start: $($startTime -f 'hh:mm:ss')";
    Invoke-Expression $expression;
    $endTtime = Get-Date;
    Write-Host "End: $($endTtime -f 'hh:mm:ss') - Elapsed: $(Get-ElapsedTime($startTime))";
}

function Write-Transcript($code) {
    if ($global:loggingEnabled) {
        $logFileName = Get-Date -Format "yyyy-MM-dd_hh-mm-ss";
        $logFile = Join-Path $scriptDir "$logFileName.log";
        Write-Host "Begin logging to $logFile";
        Start-Transcript -path $logFile -Force;
    }
	try {
	    $startTime = Get-Date;
	    Write-Host "Script starting: $($startTime -f 'hh:mm:ss')";

	    &$code;

	    $endTime = Get-Date;
	    Write-Host "";
	    Write-Host "Script complete: $($endTtime -f 'hh:mm:ss') - Elapsed: $(Get-ElapsedTime($startTime))";
	} finally {
	    if ($global:loggingEnabled) {
	        $ErrorActionPreference = "SilentlyContinue";
	        Stop-Transcript -ErrorAction "SilentlyContinue";
	        $ErrorActionPreference = "Stop";
	    }
	}
}

function Get-ElapsedTime($startTime) {
    [TimeSpan]$time = ($(get-date) - $startTime);
    return '{0}:{1}:{2}.{3}' -f `
            [Math]::Floor($time.TotalHours), $time.Minutes, $time.Seconds, $time.Milliseconds;
}
#endregion

#region ############ Deployment execution #############
function Start-Install([string]$configFileName = "install.xml", [bool]$loggingEnabled = $true) {
    $errorActionPreference = "Stop";

    #-------------------------------------------
    # Global Variables
    #-------------------------------------------
    #TODO: create XSD and validate
    $config = [xml](Get-Content -Read -1 (Get-ScriptPath $configFileName));
    $global:loggingEnabled = $loggingEnabled -AND
                             ([bool]$config.Deployment.Logging.Enabled) -AND 
                             !([environment]::commandline -LIKE '*powershell_ise.exe*') -AND
                             !([environment]::commandline -LIKE '*ScriptEditor.exe*');
    if ($global:config.Deployment.CollectUlsOnError) {
        $global:collectUls = [bool]$global:config.Deployment.CollectUlsOnError.Enabled;
    }

    Push-InstallStack $configFileName;

    #Deployment code
    $code = {
        try {
            #Load libraries
            $config.Deployment.Library | % {
                if ($_) {
                    $libraryName = $_;
                    Write-Host "Loading library $_";
                    . (Join-Path $scriptDir $libraryName);
                }
            }
        } catch {
			$e = $error[0];
            Stop-Install "Error loading dependent library: $libraryName" $e;
        }

        try {
            $step = 1;
            $config.Deployment.DeploymentSteps.SelectNodes("*") | % { 
                $name = $_.LocalName;
                $config = $_.OuterXml.Replace("'","''");
                Set-InstallStep $name $step;
                Write-Host "";
                Write-Host (Get-InstallStep);
                $expression = "$name ([xml]'$config').$name";
                Trace-function $expression;
                $step += 1;
            }
        } catch {
			$e = $error[0];
            Stop-Install "Error executing deployment $(Get-InstallStep)" $e;
        }
    }

    Write-Transcript $code;
    
    Pop-InstallStack | Out-Null;
}

function Stop-Install([string]$message,[System.Management.Automation.ErrorRecord]$ex) {
    if ($message) {
        Write-Error "";
        Write-Error $message;
        Write-Error "";
    }
	
	if ($ex) {
		Write-Exception $ex;
        Write-Host "";
	}

    $dateTime = Get-Date -Format 'M/dd/yyyy hh:mm:ss';
    Write-Host "Installation stopped $dateTime" -ForegroundColor "Red";

    Safe-Run {Stop-Transcript -ErrorAction "SilentlyContinue"; };

    Exit 1;
}
#endregion

if ($noExecute) {
	Write-Host "Install.ps1 script loaded.";
} else {
	Clear-Host;
	Start-Install -configFileName $cfg -loggingEnabled $true;
}
