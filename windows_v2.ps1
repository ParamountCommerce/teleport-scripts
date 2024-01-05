Set-StrictMode -Version Latest
#$ErrorActionPreference = "Stop"

# Show v2 release notes
if ($null -eq [Environment]::GetEnvironmentVariable("SHOW_TELEPORT_V2_RELEASE_NOTES", "User"))
{
	[Environment]::SetEnvironmentVariable("SHOW_TELEPORT_V2_RELEASE_NOTES", "no", "User")
	$wshell = New-Object -ComObject Wscript.Shell
	$answer = $wshell.Popup("`n In order for this script to work, please replace all occurances of 'host': 'paramountcommerce.teleport.sh' with 'host': 'localhost' in the file 'C:\Users\$env:username\AppData\Roaming\DBeaverData\workspace6\General\.dbeaver\data-sources.json' and restart dBeaver.`n`n`nNOTE: This is a one time activity and only needs to be done once for existing connections on dBeaver.`n`n`n Click Ok to continue`n",0,"Welcome to V2",64+1)
	if($answer -eq 2){exit}
}

$PSDefaultParameterValues['*:ErrorAction']='Stop'
$authconnector = @('Okta-Admins(DEVOPS Only)', 'Okta-Mazooma', 'Okta-PCCA')
$data = @('Teleport Login','Connect-to-RDS','Assume-Role & Connect-to-RDS','Connect-to-Kubernetes-Cluster','Teleport Logout','v2 Release Notes','Exit')
$GridArguments = @{
    OutputMode = 'Single'
    Title      = 'Please select operation and click OK'
}
# Check if there is already an active session/active session time is not less than 3 hours
function Check-Creds
 {
	 if ([string]::IsNullOrEmpty($(tsh status --format=json 2> $null | jq '.active.valid_until')))
         {
             Write-Output "Not logged in"
			 Get-Creds
         }
     elseif ((($(tsh status --format=json 2> $null | jq '.active.valid_until')).Replace("`"","") -lt (get-date).AddHours(3).ToString("yyyy-MM-ddTHH:mmK")) -eq "true")
         {
             Write-Output "Login expires soon"
			 Get-Creds
         }
     else
         {
             tsh status
         }
}
# Request access to a Teleport role
<#function Req-Access
 {
	  $request=$(tsh status | Select-String -Pattern 'Valid until')
	   $request -replace '.+\s(.+)]','$1'
}#>
# Teleport login
function Get-Creds
 {
	Ver-Check
	try
	{
		$authconnector = $authconnector | Out-GridView @GridArguments
		if ($authconnector -eq 'Okta-Admins(DEVOPS Only)')
		{
			$authconnector = 'okta'
		}
		elseif ($authconnector -eq 'Okta-Mazooma')
		{
			$authconnector = 'okta-mazooma'
		}
		elseif ($authconnector -eq 'Okta-PCCA')
		{
			$authconnector = 'okta-pcca'
		}
		tsh login --proxy=paramountcommerce.teleport.sh --auth=$authconnector
	}
	catch
	{
		Write-Output "Something threw an exception, login into Teleport on a browser and validate your credentials"
		Write-Output $_
		Exit
	}
}

# Connect to Database
function Dbms {
	try
	{
		$environment = $(tsh db ls --format=json | jq '.[].metadata.labels.Environment' | Sort-Object | Get-Unique | Out-GridView @GridArguments).Replace("`"","")
		$db_name = $(tsh db ls  --format=json Environment=$environment | jq '.[].metadata.name' | Out-GridView @GridArguments).Replace("`"","")
		$db_user = $($(tsh db ls --format=json | jq -r '[.[].users.allowed]' | Sort-Object | Get-Unique).Replace('[','.').Replace(']','').Replace('.','').Replace(',','') | Out-GridView @GridArguments).Replace("`"","")
		tsh db login $db_name --db-user $db_user --db-name postgres
#		$config = tsh db config $db_name | Out-String
		$config = tsh db config $db_name --format=json
#		$get_key_path = tsh db config $db_name | Select-String -Pattern 'Key:'
#		$key_path = $get_key_path -split ":       "
		$key_path = tsh db config $db_name --format=json | jq -r '.key'
#		openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt -in $key_path[1] -out ($key_path[1] + ".pk8")
		openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt -in $key_path -out ($key_path + ".pk8")
		Write-Host "Use the below information to configure your GUI tools"
#		Write-Host $config
		Write-Host ("DB Connection Name :       " + $(echo $config | jq -r '.name'))
		Write-Host "Host :       localhost"
		Write-Host "Port :       11144"
		Write-Host "Database :       postgres"
		Write-Host "Authentication: Database Native"
		Write-Host ("Username : " + $(echo $config | jq -r '.user'))
		Write-Host "SSL Configuration"
		Write-Host ("CA Certificate :       " + $(echo $config | jq -r '.ca'))
		Write-Host ("Client Certificate :       " + $( echo $config | jq -r '.cert'))
		Write-Host ("Client Private Key:       " + $key_path + ".pk8")
		if ([string]::IsNullOrEmpty($((netstat -ano | select-string 11144) -replace '.+\s(.+)','$1')))
         {
			$proxy_tunnel = {param($db) tsh proxy db $db --port=11144}
			Start-Job $proxy_tunnel -Arg $db_name
		}
		continue
	}
	catch
	{
		Write-Output "Not logged into teleport, redirecting to teleport login..."
		Get-Creds
		Dbms
		continue
	}
}

# Assume role based on request that user selects
function Spl
 {
	if ([string]::IsNullOrEmpty($(tsh requests ls --format=json 2> $null | jq '.[].metadata.name')))
         {
		Write-Output "!NO ACTIVE ACCESS REQUESTS FOUND! Please make sure you have an access request submitted before using this feature."
		continue
	}
	else
	{
		try
		{
			Check-Creds
#			$id = $(tsh requests ls --format=json | jq '.[].metadata.name' | Out-GridView @GridArguments).Replace("`"","")
			$id = $(tsh requests ls | Select-Object -SkipLast 2 | Out-GridView @GridArguments).Replace("`"","")
			$request = $id.split(' ')[0]
			Write-Output ("Request ID:       " + $request)
			tsh login  --request-id=$request
		}
		catch
		{
			Write-Output "Something threw an exception, Please make sure you have an access request submitted before using this feature."
		Write-Output $_
			Exit
		}
	}
}

function Ver-Check
{
	$response_version_server = $( Invoke-RestMethod -Uri https://paramountcommerce.teleport.sh/webapi/ping -UseBasicParsing )
	$server_teleport_version = $response_version_server.server_version
	$local_teleport_version = $( tsh version --format=json | jq .version )  -replace '"', ''
	$local_minor_version = $local_teleport_version.LastIndexOf('.')
	if ($local_minor_version -ne -1) {
    	$local_teleport_version = $local_teleport_version.Substring(0, $local_minor_version)
	}
	$server_minor_version = $server_teleport_version.LastIndexOf('.')
	if ($server_minor_version -ne -1) {
    	$server_teleport_version = $server_teleport_version.Substring(0, $server_minor_version)
	}
	if ($server_teleport_version -gt $local_teleport_version) {
    	Write-Output "The current teleport cloud cluster version ($server_teleport_version) is older than the local client version $local_teleport_version."
    	Write-Output "Your local client version needs to be ($server_teleport_version) or higher"
		Write-Output "Download latest 'tsh client' for Windows from here: https://goteleport.com/download/#:~:text=Download%20Teleport,tsh%20client"
		exit
	}
}

function K8s-Login
{
	set KUBECONFIG=${HOME}/teleport-kubeconfig.yaml
	$clusters = $(tsh kube ls --format=json | jq '.[].kube_cluster_name' | Sort-Object | Get-Unique | Out-GridView @GridArguments).Replace("`"","")
	tsh kube login $clusters
}

do {
		$choice = $data | Out-GridView @GridArguments
		switch ($choice)
		{
		'Teleport Login' {
			Get-Creds
		}
		'Connect-to-RDS' {
			Check-Creds
			Dbms
		}
		'Assume-Role & Connect-to-RDS' {
			Check-Creds
			Spl
			Dbms
		}
		'Connect-to-Kubernetes-Cluster' {
			Check-Creds
			K8s-Login
		}
		'Teleport Logout' {
			tsh logout
			Start-Job -ScriptBlock {  taskkill /F /PID $((netstat -ano | select-string 11144) -replace '.+\s(.+)','$1') }
		}
		'v2 Release Notes' {
			Write-Output "`n Hello, we recently upgraded our teleport cluster to use TLS and in order for this script to work, please replace all occurances of 'host': 'paramountcommerce.teleport.sh' with 'host': 'localhost' in the file 'C:\Users\$env:username\AppData\Roaming\DBeaverData\workspace6\General\.dbeaver\data-sources.json' and restart dBeaver.`n`n`n"
		}
		'Exit' {
			exit
		}
		}
} until ($choice -eq 'Exit')