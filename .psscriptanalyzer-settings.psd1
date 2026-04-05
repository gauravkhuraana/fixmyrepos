@{
    ExcludeRules = @(
        # This is an interactive CLI tool — Write-Host is intentional for colored console output.
        'PSAvoidUsingWriteHost'
    )
}
