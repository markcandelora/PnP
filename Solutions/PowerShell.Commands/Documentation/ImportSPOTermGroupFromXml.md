#Import-SPOTermGroupFromXml
*Topic automatically generated on: 2015-06-03*

Imports a taxonomy TermGroup from either the input or from an XML file.
##Syntax
```powershell
Import-SPOTermGroupFromXml [-Path <String>]
```


```powershell
Import-SPOTermGroupFromXml [-Xml <String>]
```


##Parameters
Parameter|Type|Required|Description
---------|----|--------|-----------
|Path|String|False|The XML File to import the data from|
|Xml|String|False|The XML to process|
##Examples

###Example 1
    PS:> Import-SPOTermGroupFromXml -Xml $xml
Imports the XML based termgroup information located in the $xml variable

###Example 2
    PS:> Import-SPOTermGroupFromXml -Path input.xml
Imports the XML file specified by the path.
<!-- Ref: 8272C3B57473307FEC8D2F15B9E17095 -->