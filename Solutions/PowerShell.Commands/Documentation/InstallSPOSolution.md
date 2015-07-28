#Install-SPOSolution
*Topic automatically generated on: 2015-06-03*

Installs a sandboxed solution to a site collection
##Syntax
```powershell
Install-SPOSolution -PackageId <GuidPipeBind> -SourceFilePath <String> [-MajorVersion <Int32>] [-MinorVersion <Int32>]
```


##Parameters
Parameter|Type|Required|Description
---------|----|--------|-----------
|MajorVersion|Int32|False|Optional major version of the solution, defaults to 1|
|MinorVersion|Int32|False|Optional minor version of the solution, defaults to 0|
|PackageId|GuidPipeBind|True|ID of the solution, from the solution manifest|
|SourceFilePath|String|True|Path to the sandbox solution package (.WSP) file|
<!-- Ref: FCB71AA28DE99539CD3F4299809E3720 -->