param(
    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
	[string] $PowerBIDirectory = "./PowerBiNew/tree/Master/PowerBI_CICD/PowerBI/Report/PowerBI_CICD",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
	[string] $DatasetWorkspaceName = "My-Space",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
	[string] $DatasetName = "SharedDataset",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $BuildAgentLogin = "dhananjay@cloudaeon.net",

    #[Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $BuildAgentPassword = "LIfe@@787898",
    


    #[Parameter(Mandatory = $True)]
	[ValidateNotNullOrEmpty()]
	[string] $ReportsToDeploy = '[
        {"Workspace":"My-Space","Folder":"PowerBI_CICD","ReportName":"Report1"},
        {"Workspace":"My-Space","Folder":"PowerBI_CICD","ReportName":"Report2"}
    ]',

	#[Parameter(Mandatory = $False)]
    [string] $InstallModules = "True"
)


###EXECUTION
cls;

Write-Host "### Script Started.";
Write-Host "Now logged in as $BuildAgentLogin"

try
{
    ### INSTALL MODULES AND LOGIN TO POWER ###
	if($InstallModules -eq "True")
	{
		install-PackageProvider `
			-Name "Nuget" `
			-Force `
			-Scope CurrentUser;

		install-module `
			-Name "MicrosoftPowerBIMgmt.Profile" `
			-AllowClobber `
			-Force `
			-Scope CurrentUser;
        install-module `
			-Name "MicrosoftPowerBIMgmt.Workspaces" `
			-AllowClobber `
			-Force `
			-Scope CurrentUser;
 

	}

    $secureBuildAgentPassword = ConvertTo-SecureString $BuildAgentPassword `
        -AsPlainText `
        -Force;
    
    $creds = New-Object PSCredential($BuildAgentLogin,$secureBuildAgentPassword);
    Login-PowerBIServiceAccount -Credential $creds;




    ### REDEPLOY REPORTS ###
    $reports = $ReportsToDeploy | ConvertFrom-Json ;
    Write-Host "ReportsCount: $($reports.Count)"
    foreach($report in $reports)
    {
        Write-Host "Workspace: $($report.Workspace)";
        Write-Host "Report: $($report.ReportName)";


        ## GET WORKSPACE ID
        Write-Host "Getting workspaces."
        Write-Host $reportWorkspace.Id
        $reportWorkspace = Get-PowerBIWorkspace -Name $report.Workspace;

        if($reportWorkspace -eq $null)
        {
            throw "Can not find $($report.Workspace) Workspace in available workspaces.";
        }

        ## GET REPORT ID
        Write-Host "Getting Report"
        $existingreport = Get-PowerBIReport -WorkspaceId $reportWorkspace.Id -Name $report.ReportName;
        $PowerBIFilePath = "$($PowerBIDirectory)\$($report.Folder)\$($report.ReportName).pbix";


        ## DEPLOY POWER BI REPORT
        if($existingreport -eq $null)
        {
            #CREATE NEW POWER BI REPORT
            Write-Host "Creating New PowerBI Report...";
            New-PowerBIReport `
	            -Path $PowerBIFilePath `
	            -Name $report.ReportName `
	            -WorkspaceId $reportWorkspace.Id `
                -Timeout 3600 `
                -ErrorAction Stop;

            Write-Host "Created New PowerBI Report" -ForegroundColor Green;
        }
        else
        {
            ## UPDATE REPORT WHEN EXISTS (DROP AND RECREATE)
            Write-Host "Report Exists. Updating PowerBI Report..." -ForegroundColor Yellow;
            Remove-PowerBIReport `
                -WorkspaceId $reportWorkspace.Id `
                -Id $existingreport.Id `
                -ErrorAction Stop;;

            New-PowerBIReport `
	            -Path $PowerBIFilePath `
	            -Name $report.ReportName `
	            -WorkspaceId $reportWorkspace.Id `
                -ErrorAction Stop;
        
            Write-Host "Updated PowerBI Report" -ForegroundColor Green;
        }

    


        ### REBIND NEW REPORT TO DATASET (DEV, TEST, PROD) ETC. ###
        ## GET NEW REPORT INFORMATION
        Write-Host "Getting New Report Information";
        $newReport = Get-PowerBIReport -WorkspaceId $reportWorkspace.Id.Guid -Name $report.ReportName;

        ## GET DATASET INFORMATION
        Write-Host "Getting Dataset Workspace Information";
        $datasetWorkspace = Get-PowerBIWorkspace -Name $DatasetWorkspaceName;
     
        Write-Host "Getting Dataset Information";
        $dataset = Get-PowerBIDataset -WorkspaceId $datasetWorkspace.Id.Guid -Name $DatasetName -ErrorAction Stop;

        ## SEND REQUEST 
        $requestBody = @{datasetId = $dataset.Id.Guid};
        $requestBodyJson = $requestBody | ConvertTo-Json -Compress;  
          
        $headers = Get-PowerBIAccessToken;
        $result = Invoke-RestMethod `
            -Headers $headers `
            -Method "Post" `
            -ContentType "application/json" `
            -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($reportWorkspace.Id.Guid)/reports/$($newReport.Id.Guid)/Rebind" `
            -Body $requestBodyJson `
            -Timeout 3600 `
            -ErrorAction Stop;

        Write-Host "Rebinded";
        Write-Host "";

        Write-Host "Deployed and Rebinded Succesfully" -ForegroundColor Green;
        Write-Host "----------------";
    }
    Write-Host "### Script Finished Succesfully." -ForegroundColor Green;
} 
catch
{
    Write-Host "### Script Failed." -ForegroundColor Red;
    throw;
}
