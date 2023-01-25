param(
    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
	[string] $PowerBIFilePath = "C:\src\PowerBI_CICD\PowerBI\SharedDataset\SharedDataSet.pbix",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
	[string] $WorkspaceName = "PowerBI_CICD_Dev",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
	[string] $SharedDatasetName = "SharedDataset",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $BuildAgentLogin = "",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String] $BuildAgentPassword = "",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceSqlServer = "pbicicd-dev-sql.database.windows.net",
    
    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceDatabase = "pbicicd-dev-sqldb",
        
    [Parameter(Mandatory = $false)]
    [string] $GatewayName= "PBIGatewayDev",

    [Parameter(Mandatory = $false)]
    [string] $ScheduleJson = '{"value":{"enabled":true,"days":["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"],"times":["06:00"],"localTimeZoneId":"UTC"}}',

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $InstallLibraries = "True"
)

cls;

Write-Host "### Script Started.";

try
{
    ## INSTALL MODULES AND LOGIN TO POWER 
    if($InstallLibraries -eq "True")
    {
        install-PackageProvider `
            -Name "Nuget" `
            -Force `
            -Scope CurrentUser;

        install-module `
            -Name "MicrosoftPowerBIMgmt" `
            -AllowClobber `
            -Force `
            -Scope CurrentUser
    }
    $secureBuildAgentPassword = ConvertTo-SecureString $BuildAgentPassword `
        -AsPlainText `
        -Force;

    $creds = New-Object PSCredential($BuildAgentLogin,$secureBuildAgentPassword);
    Login-PowerBIServiceAccount -Credential $creds;

    ## GET WORKSPACE ID
    Write-Host "Getting workspaces..."

    $workspace = Get-PowerBIWorkspace -All | Where-Object { $_.Name -eq $WorkspaceName };

    if($null -eq $workspace)
    {
        throw "Can not find $($WorkspaceName) Workspace in available workspaces.";
    }

    ## GET REPORT ID
    Write-Host "Trying to obtain existing report..."
    $existingReport = Get-PowerBIReport -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq $SharedDatasetName };

    #CREATE NEW POWER BI REPORT
    Write-Host "## Creating New PowerBI Report...";
    New-PowerBIReport `
	    -Path $PowerBIFilePath `
	    -Name $SharedDatasetName `
	    -WorkspaceId $workspace.Id.Guid `
        -ErrorAction Stop `
        -Timeout 3600;

    $newDataset = Get-PowerBIDataset -WorkspaceId $workspace.Id.Guid -Name $SharedDatasetName | Where-Object {$_.Id -ne $existingReport.DatasetId};

    ## DEPLOY POWER BI REPORT
    if($null -eq $existingReport)
    {
        Write-Host "Created New PowerBI Report" -ForegroundColor "Green";
    }
    else
    {       
        Write-Host "Created Updated PowerBI Report for" -ForegroundColor "Green";
		
        ## REBIND REPORTS TO NEW DATASET
        Write-Host "Checking dependant reports...";
        $reportWorkspaces = Get-PowerBIWorkspace  | Where-Object {$_.Name -ne $WorkspaceName};
        foreach($reportWorkspace in $reportWorkspaces)
        {
            $reportsToRebind = (Get-PowerBIReport -WorkspaceId $reportWorkspace.Id.Guid)  | Where-Object { $_.DatasetId -eq $existingReport.DatasetId -and $_.Name -ne $SharedDatasetName};
    
            if($null -ne $reportsToRebind)
            {
                Write-Host ""
                Write-Host "Workspace reports To Rebind: $($reportWorkspace.Name)"
                Write-Host "Reports To Rebind Count: $($reportsToRebind.Count)"
                $requestBody = @{datasetId = $newDataset.Id.Guid};
                $requestBodyJson = $requestBody | ConvertTo-Json -Compress;
                foreach($reportToRebind in $reportsToRebind)
                {
                    $headers = Get-PowerBIAccessToken;
                    Invoke-RestMethod `
                        -Headers $headers `
                        -Method "Post" `
                        -ContentType "application/json" `
                        -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($reportWorkspace.Id.Guid)/reports/$($reportToRebind.Id.Guid)/Rebind" `
                        -Body $requestBodyJson `
                        -ErrorAction Stop;
    
                    Write-Host "Rebinded Report: $($reportToRebind.Name)";
                    Write-Host "------";
                }
            }
        }

        ## REMOVE OLD REPORT
        Write-Host "Removing old report";
        Remove-PowerBIReport `
            -WorkspaceId $workspace.Id `
            -Id $existingReport.Id.Guid `
            -ErrorAction Stop;
    
        ## REMOVE OLD DATASET
        Write-Host "Removing old Dataset"
        $headers = Get-PowerBIAccessToken;
        Invoke-RestMethod `
            -Headers $headers `
            -Method "Delete" `
            -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id.Guid)/datasets/$($existingReport.DatasetId)" `
            -ErrorAction Stop; 

    }


    ## UPDATE DATASET PARAMETERS
    ## SEND REQUEST
    Write-Host "Updating DataSet Parameters...";
    $Parameters = @{
        "updateDetails"= @(
            @{
                "name"="ServerName";
                "newValue"="$($SourceSqlServer)";
             },
            @{
                "name"="DatabaseName";
                "newValue"="$($SourceDatabase)";
             }
          )
    };

    $ParametersJson = $Parameters | ConvertTo-Json -Compress;

    $headers = Get-PowerBIAccessToken;
    Invoke-RestMethod `
        -Headers $headers `
        -Method "Post" `
        -ContentType "application/json" `
        -Uri "https://api.powerbi.com/v1.0/myorg/datasets/$($newDataset.Id.Guid)/Default.UpdateParameters" `
        -Body $ParametersJson `
        -ErrorAction Stop;

    Write-Host "Updated DataSet Parameters" -ForegroundColor Green;


    ## GET GATEWAY AND CONNECTIONS
    if($GatewayName -ne $null)
    {
        Write-Host "Connecting to gateway";
        $headers = Get-PowerBIAccessToken;
        $gatewaysResponse = Invoke-RestMethod `
            -Headers $headers `
            -Method "Get" `
            -Uri "https://api.powerbi.com/v1.0/myorg/gateways" `
            -ErrorAction Stop;

        $gateway = $gatewaysResponse.value | Where-Object {$_.name -like $GatewayName};

        ## GET GATEWAY DATA SOURCES
        $headers = Get-PowerBIAccessToken;
        Invoke-RestMethod `
            -Headers $headers `
            -Method "Get" `
            -Uri "https://api.powerbi.com/v1.0/myorg/gateways/$($gateway.Id)/datasources";

        ## CONNECT TO GATEWAY
        Write-Host "Binding to gateway";
        $requestBody = @{
          "gatewayObjectId"= $gateway.id;
        }

        $requestBodyJson = $requestBody | ConvertTo-Json -Compress;
        $headers = Get-PowerBIAccessToken;
        Invoke-RestMethod `
            -Headers $headers `
            -Method "Post" `
            -ContentType "application/json" `
            -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.Id.Guid)/datasets/$($newDataset.Id.Guid)/Default.BindToGateway" `
            -Body $requestBodyJson `
            -ErrorAction Stop;

        Write-Host "Report Binded to Gateway" -ForegroundColor Green;
    }

    ### Creating Refresh Schedule if provided
    if($ScheduleJson -ne $null)
    {
        Write-Host "Creating Refresh Schedule...";
	    $headers = Get-PowerBIAccessToken;
        Invoke-RestMethod `
            -Headers $headers `
            -Method "Patch" `
            -ContentType "application/json" `
            -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($Workspace.Id.Guid)/datasets/$($newDataset.Id.Guid)/refreshSchedule" `
            -Body $ScheduleJson `
            -ErrorAction Stop;

	    Write-Host "Created Refresh Schedule" -ForegroundColor Green;
    }
    Write-Host "### Script Finished Succesfully.";
} 
catch
{
    Write-Host "### Script Failed." -ForegroundColor Red;
    throw;
}




