BeforeAll {
    $supervisorPath = Join-Path $PSScriptRoot '../supervisor/runner-supervisor.ps1'
    $syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($supervisorPath, [ref]$null, [ref]$null)
    $assertion = $syntaxTree.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-RunnerTargetPrivate'
        }, $true)
    . ([scriptblock]::Create($assertion.Extent.Text))

    function Invoke-GitHub([string]$Method, [string]$Path, $Body) { }
}

Describe 'Assert-RunnerTargetPrivate' {
    Context 'repository mode' {
        BeforeEach {
            $Organization = ''
            $Repository = 'owner/repo'
            $scope = 'repos/owner/repo'
        }

        It 'accepts a private repository' {
            Mock Invoke-GitHub { [pscustomobject]@{ private = $true } }

            { Assert-RunnerTargetPrivate } | Should -Not -Throw
            Should -Invoke Invoke-GitHub -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Path -eq 'repos/owner/repo' }
        }

        It 'refuses a public repository' {
            Mock Invoke-GitHub { [pscustomobject]@{ private = $false } }

            { Assert-RunnerTargetPrivate } | Should -Throw "Repository 'owner/repo' is public; these runners only serve private repositories."
        }

        It 'treats a missing private field as public' {
            Mock Invoke-GitHub { [pscustomobject]@{ name = 'repo' } }

            { Assert-RunnerTargetPrivate } | Should -Throw "Repository 'owner/repo' is public*"
        }
    }

    Context 'organization mode' {
        BeforeEach {
            $Organization = 'my-org'
            $Repository = ''
            $RunnerGroupId = 7
            $scope = 'orgs/my-org'
        }

        It 'accepts a runner group closed to public repositories' {
            Mock Invoke-GitHub { [pscustomobject]@{ name = 'Default'; allows_public_repositories = $false } }

            { Assert-RunnerTargetPrivate } | Should -Not -Throw
            Should -Invoke Invoke-GitHub -Times 1 -ParameterFilter { $Path -eq 'orgs/my-org/actions/runner-groups/7' }
        }

        It 'refuses a runner group that allows public repositories' {
            Mock Invoke-GitHub { [pscustomobject]@{ name = 'Default'; allows_public_repositories = $true } }

            { Assert-RunnerTargetPrivate } | Should -Throw "Runner group 'Default' allows public repositories*"
        }
    }
}
