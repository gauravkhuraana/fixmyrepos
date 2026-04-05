@{
    ExcludeRules = @(
        # Interactive CLI tool -- Write-Host is intentional for colored console output
        'PSAvoidUsingWriteHost'
        # Internal helper functions, not exported module cmdlets -- naming rules don't apply
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        # Write-Log is a custom logger for this script, not overriding the built-in
        'PSAvoidOverwritingBuiltInCmdlets'
        # Update-RateLimit only modifies script-scoped variables, not system state
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
