# IntuneTenantCloneKit root module.
# Dot-sources every function in Public/ and exports them by name.
$Public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter *.ps1 -ErrorAction SilentlyContinue)

foreach ($file in $Public) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error "Failed to load $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $Public.BaseName
