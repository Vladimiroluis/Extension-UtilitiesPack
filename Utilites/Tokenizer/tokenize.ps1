﻿[CmdletBinding(DefaultParameterSetName = 'None')]
param
(
    #SourceFile that contains environment specific information which needs to be transformed based on the environment
    [String] [Parameter(Mandatory = $true)][ValidateNotNullorEmpty()] $SourcePath,
    #DestinationFile that will have the transformed $SourcePath, if empty then $SourcePath will be used as $DestinationPath
    [String] [Parameter(Mandatory = $false)] $DestinationPath,
    #ConfigurationJsonFile contains the environment specific configuration values, XPath key value pairs that will be used for XML documents passed as $SourcePath
    [String] [Parameter(Mandatory = $false)] $ConfigurationJsonFile,
    #Replace undefined values with empty
    [Parameter(Mandatory = $false)] $ReplaceUndefinedValuesWithEmpty    
)

# A hack becoz it doesn't work otherwise
try {
  $ReplaceUndefinedValuesWithEmpty = [System.Convert]::ToBoolean($ReplaceUndefinedValuesWithEmpty) 
} catch [FormatException] {
  $ReplaceUndefinedValuesWithEmpty = $false
}

Write-Verbose "Entering script tokenize.ps1"
Write-Verbose "SourcePath = $SourcePath"
Write-Verbose "DestinationPath = $DestinationPath"
Write-Verbose "ConfigurationJsonFile = $ConfigurationJsonFile"
Write-Verbose "ReplaceUndefinedValuesWithEmpty = $ReplaceUndefinedValuesWithEmpty"

. $PSScriptRoot\Helpers.ps1

#ConfigurationJsonFile has multiple environment sections.
$environmentName = "default"
if (Test-Path -Path env:RELEASE_ENVIRONMENTNAME) {
    $environmentName = (get-item env:RELEASE_ENVIRONMENTNAME).value
}
Write-Host "Environment: $environmentName"

# Validate that $SourcePath is a valid path
Write-Verbose "Validate that SourcePath is a valid path: $SourcePath"
if (!(Test-Path -Path $SourcePath)) {
    throw "$SourcePath is not a valid path. Please provide a valid path"
}

# Set $DestinationPath as $SourcePath if it is not passed as input. So, SourceFile gets transformed as DestinationFile
if ($DestinationPath -eq "") {
    Write-Verbose "No DestinationPath passed. Use '$SourcePath' as DestinationPath"
    $DestinationPath = $SourcePath
}

# Is SourceFile an XML document
$SourceIsXml=Test-ValidXmlFile $SourcePath
# Is there a valid Configuration Json input provided for modifying configuration
if ($ConfigurationJsonFile -ne "") {
    Write-Verbose "Using configuration from '$ConfigurationJsonFile'"
    $Configuration = Get-JsonFromFile $ConfigurationJsonFile
} 

# Create a copy of the source file and manipulate it
$tempFile = $DestinationPath + '.tmp'
Copy-Item -Force $SourcePath $tempFile -Verbose

<#
    Step 1:- if the SourceIsXml and a valid configuration file is provided then 
        Run through all the XPaths in the Json Configuration and update the XML file
#>
if (($SourceIsXml) -and ($Configuration)) {
    Write-Verbose "'$SourcePath' is a XML file. Apply all configurations from '$ConfigurationJsonFile'"

    $keys = $Configuration.$environmentName.ConfigChanges

    $xmlraw = [xml](Get-Content $SourcePath)
    ForEach ($key in $keys) {
        # Check for a namespaced element
        if ($key.NamespaceUrl -And $key.NamespacePrefix) {
            $ns = New-Object System.Xml.XmlNamespaceManager($xmlraw.NameTable)
            $ns.AddNamespace($key.NamespacePrefix, $key.NamespaceUrl)
            $node = $xmlraw.SelectSingleNode($key.KeyName, $ns)
        } else {
            $node = $xmlraw.SelectSingleNode($key.KeyName)
        }

        if ($node) {
            try {
                Write-Host "Updating $($key.Attribute) of $($key.KeyName): $($key.Value)"
                $node.($key.Attribute) = $key.Value
            }
            catch {
                Write-Error "Failure while updating $($key.Attribute) of $($key.KeyName): $($key.Value)"
            }
        }
    }
    $xmlraw.Save($tempFile)
}

<#
  Step 2:- For each token in the source configuration that matches with the regular expression __<tokenname>__
            i.	If there is a custom variable at build or release definition then replace the token with the value of the same..
            ii.	If the variable is available in the configuration section of json document then replace the token with the vaule from json document
            iii.Or else it ignores the token
#>
$regex = '__[A-Za-z0-9._-]*__'
$matches = select-string -Path $tempFile -Pattern $regex -AllMatches | % { $_.Matches } | % { $_.Value }
ForEach ($match in $matches) {
  Write-Host "Updating token '$match'" 
  $matchedItem = $match
  $matchedItem = $matchedItem.Trim('_')
  $matchedItem = $matchedItem -replace '\.','_'
  
  $variableValue = $match
  try {
      if (Test-Path env:$matchedItem) {
          $variableValue = (get-item env:$matchedItem).Value
          Write-Verbose "Found custom variable '$matchedItem' in build or release definition with value '$variableValue'" 
      }
      else {
          if ($Configuration.$environmentName.CustomVariables.$matchedItem) {
              $variableValue = $Configuration.$environmentName.CustomVariables.$matchedItem
              Write-Verbose "Found variable '$matchedItem' in configuration with value '$variableValue" 
          }
          else {
              Write-Host "No value found for token '$match'"
              if ($ReplaceUndefinedValuesWithEmpty) {
                  Write-Host "Setting '$match' to an empty value."
                  # Explicitely set token to empty value if neither environment variable was set nor the value be found in the configuration.
                  $variableValue = [string]::Empty
              }
          }
      }
  }
  catch {
      Write-Host "Error searching for variable for token '$match'"
  }
  
  (Get-Content $tempFile) | 
    Foreach-Object {
        $_ -replace $match, $variableValue
    } |
    Set-Content $tempFile -Force
}

Copy-Item -Force $tempFile $DestinationPath
Remove-Item -Force $tempFile
