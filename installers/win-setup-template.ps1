[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"
[String] $PythonPackageId = "{{__PYTHON_PACKAGE_ID__}}"

# Python install manager used to install Python 3.16+ packages (PEP 773)
[String] $PyManagerVersion = "26.4"
[String] $PyManagerSha256 = "ab8c6b8a484525b000e8e9453fde0ed6cdef762dd433622725696a8e1ef2df4e"

function Get-PyManagerPath {
    $Command = Get-Command pymanager -ErrorAction SilentlyContinue
    if ($Command) {
        return $Command.Source
    }

    Write-Host "Install Python install manager $PyManagerVersion"
    $Installer = Join-Path -Path $env:TEMP -ChildPath "python-manager-$PyManagerVersion.msi"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/pymanager/python-manager-$PyManagerVersion.msi" -OutFile $Installer
    $ActualHash = (Get-FileHash -Path $Installer -Algorithm SHA256).Hash
    if ($ActualHash -ne $PyManagerSha256) {
        Throw "SHA-256 mismatch for Python install manager: expected $PyManagerSha256, got $ActualHash"
    }

    $Process = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$Installer`" /qn /norestart" -Wait -PassThru
    if ($Process.ExitCode -ne 0) {
        Throw "Error happened during Python install manager installation (exit code $($Process.ExitCode))"
    }

    $Executable = Get-ChildItem -Path $env:ProgramFiles, ${env:ProgramFiles(x86)} -Filter pymanager.exe -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $Executable) {
        Throw "Python install manager was installed, but pymanager.exe was not found"
    }

    return $Executable.FullName
}

function Get-RegistryVersionFilter {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    # ARM64 Python installer registers as "(ARM64)" in the display name, not "(64-bit)"
    $archFilter = switch ($Architecture) {
        'x86'   { "32-bit" }
        'arm64' { "64-bit|ARM64" }
        default { "64-bit" }
    }    
    "Python $MajorVersion.$MinorVersion.*($archFilter)"
}

function Remove-RegistryEntries {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    $versionFilter = Get-RegistryVersionFilter -Architecture $HardwareArchitecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

    $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products"
    if (Test-Path -Path Registry::$regPath) {
        $regKeys = Get-ChildItem -Path Registry::$regPath -Recurse | Where-Object Property -Ccontains DisplayName
        foreach ($key in $regKeys) {
            if ($key.getValue("DisplayName") -match $versionFilter) {
                Remove-Item -Path $key.PSParentPath -Recurse -Force -Verbose
            }
        }
    }

    $regPath = "HKEY_CLASSES_ROOT\Installer\Products"
    if (Test-Path -Path Registry::$regPath) {
        Get-ChildItem -Path Registry::$regPath | Where-Object { $_.GetValue("ProductName") -match $versionFilter } | ForEach-Object {
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }

    $uninstallRegistrySections = @(
        "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall",  # current user, x64
        "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall", # all users, x64
        "HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",  # current user, x86
        "HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"  # all users, x86
    )

    $uninstallRegistrySections | Where-Object { Test-Path -Path Registry::$_ } | ForEach-Object {
        Get-ChildItem -Path Registry::$_ | Where-Object { $_.getValue("DisplayName") -match $versionFilter } | ForEach-Object {
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }
}

function Get-ExecParams {
    param(
        [Parameter(Mandatory)][Boolean] $IsMSI,
        [Parameter(Mandatory)][Boolean] $IsFreeThreaded,
        [Parameter(Mandatory)][String] $PythonArchPath
    )

    if ($IsMSI) {
        "TARGETDIR=$PythonArchPath ALLUSERS=1"
    } else {
        $Include_freethreaded = if ($IsFreeThreaded) { "Include_freethreaded=1" } else { "" }
        "DefaultAllUsersTargetDir=$PythonArchPath InstallAllUsers=1 $Include_freethreaded"
    }
}

$ToolcacheRoot = $env:AGENT_TOOLSDIRECTORY
if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
    # GitHub images don't have `AGENT_TOOLSDIRECTORY` variable
    $ToolcacheRoot = $env:RUNNER_TOOL_CACHE
}
$PythonToolcachePath = Join-Path -Path $ToolcacheRoot -ChildPath "Python"
$PythonVersionPath = Join-Path -Path $PythonToolcachePath -ChildPath $Version
$PythonArchPath = Join-Path -Path $PythonVersionPath -ChildPath $Architecture

$IsZip = $PythonExecName -match "\.zip$"
$IsMSI = $PythonExecName -match "msi"
$IsFreeThreaded = $Architecture -match "-freethreaded"

$MajorVersion = $Version.Split('.')[0]
$MinorVersion = $Version.Split('.')[1]

Write-Host "Check if Python hostedtoolcache folder exist..."
if (-Not (Test-Path $PythonToolcachePath)) {
    Write-Host "Create Python toolcache folder"
    New-Item -ItemType Directory -Path $PythonToolcachePath | Out-Null
}

Write-Host "Check if current Python version is installed..."
$InstalledVersions = Get-Item "$PythonToolcachePath\$MajorVersion.$MinorVersion.*\$Architecture"

if ($null -ne $InstalledVersions) {
    Write-Host "Python$MajorVersion.$MinorVersion ($Architecture) was found in $PythonToolcachePath..."

    foreach ($InstalledVersion in $InstalledVersions) {
        if (Test-Path -Path $InstalledVersion) {
            Write-Host "Deleting $InstalledVersion..."
            Remove-Item -Path $InstalledVersion -Recurse -Force
            if (Test-Path -Path "$($InstalledVersion.Parent.FullName)/${Architecture}.complete") {
                Remove-Item -Path "$($InstalledVersion.Parent.FullName)/${Architecture}.complete" -Force -Verbose
            }
        }
    }
} else {
    Write-Host "No Python$MajorVersion.$MinorVersion.* found"
}

if (-not $IsZip) {
    Write-Host "Remove registry entries for Python ${MajorVersion}.${MinorVersion}(${Architecture})..."
    Remove-RegistryEntries -Architecture $Architecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion
}

Write-Host "Create Python $Version folder in $PythonToolcachePath"
if ($IsZip) {
    # $PythonArchPath is a junction to the install manager's directory
    New-Item -ItemType Directory -Path $PythonVersionPath -Force | Out-Null
} else {
    New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null
}

if ($IsZip) {
    # Python 3.16+ is distributed as a package (PEP 773) that is installed with the Python install manager.
    # Installs are in a flat directory, named after the package ID, and registered for py.exe.
    # The toolcache directory is a junction to it.
    $PyManager = Get-PyManagerPath
    $PyManagerInstallDir = Join-Path -Path $ToolcacheRoot -ChildPath "PythonManager"
    $PyManagerConfig = Join-Path -Path $env:TEMP -ChildPath "pymanager.json"
    @{ install_dir = $PyManagerInstallDir; automatic_install = $false; confirm = $false } | ConvertTo-Json | Out-File -FilePath $PyManagerConfig -Encoding utf8
    $Env:PYTHON_MANAGER_CONFIG = $PyManagerConfig

    Write-Host "Install Python $Version ($PythonPackageId) in $PyManagerInstallDir..."
    & $PyManager install --by-id --force -y --source "$PWD\index.json" $PythonPackageId
    if ($LASTEXITCODE -ne 0) {
        Throw "Error happened during Python installation"
    }

    $PyManagerPythonPath = Join-Path -Path $PyManagerInstallDir -ChildPath $PythonPackageId
    Write-Host "Link $PythonArchPath to $PyManagerPythonPath"
    New-Item -ItemType Junction -Path $PythonArchPath -Target $PyManagerPythonPath | Out-Null

    # Debug symbols are only in the "pythontest" package and were not installed by the legacy installers
    Get-ChildItem -Path $PyManagerPythonPath -Recurse -Filter "*.pdb" | Remove-Item -Force
} else {
    Write-Host "Copy Python binaries to $PythonArchPath"
    Copy-Item -Path ./$PythonExecName -Destination $PythonArchPath | Out-Null

    Write-Host "Install Python $Version in $PythonToolcachePath..."
    $ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

    cmd.exe /c "cd $PythonArchPath && call $PythonExecName $ExecParams /quiet"
    if ($LASTEXITCODE -ne 0) {
        Throw "Error happened during Python installation"
    }

    if ($IsFreeThreaded) {
        # Delete python.exe and create a symlink to free-threaded exe
        Remove-Item -Path "$PythonArchPath\python.exe" -Force
        New-Item -Path "$PythonArchPath\python.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python${MajorVersion}.${MinorVersion}t.exe"
    }
}

Write-Host "Create `python3` symlink"
New-Item -Path "$PythonArchPath\python3.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python.exe"

Write-Host "Install and upgrade Pip"
$Env:PIP_ROOT_USER_ACTION = "ignore"
$PythonExePath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
cmd.exe /c "$PythonExePath -c ""import pip"" 2>NUL"
if ($LASTEXITCODE -ne 0) {
    cmd.exe /c "$PythonExePath -m ensurepip"
    if ($LASTEXITCODE -ne 0) {
        Throw "Error happened during ensurepip execution"
    }
}
cmd.exe /c "$PythonExePath -m pip install --upgrade --force-reinstall pip --no-warn-script-location"
if ($LASTEXITCODE -ne 0) {
    Throw "Error happened during pip installation / upgrade"
}

Write-Host "Create complete file"
New-Item -ItemType File -Path $PythonVersionPath -Name "$Architecture.complete" | Out-Null
