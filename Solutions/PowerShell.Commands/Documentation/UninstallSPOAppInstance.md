#Uninstall-SPOAppInstance
*Topic automatically generated on: 2015-06-03*

Removes an app from a site
##Syntax
```powershell
Uninstall-SPOAppInstance -Identity <AppPipeBind> [-Force [<SwitchParameter>]] [-Web <WebPipeBind>]
```


##Parameters
Parameter|Type|Required|Description
---------|----|--------|-----------
|Force|SwitchParameter|False||
|Identity|AppPipeBind|True|Appinstance or Id of the addin to remove.|
|Web|WebPipeBind|False|The web to apply the command to. Omit this parameter to use the current web.|
##Examples

###Example 1
    PS:> Uninstall-SPOAppInstance -Identity $appinstance


###Example 2
    PS:> Uninstall-SPOAppInstance -Identity 99a00f6e-fb81-4dc7-8eac-e09c6f9132fe

<!-- Ref: D1946E6C7413D53CD25A5B1695D433C0 -->