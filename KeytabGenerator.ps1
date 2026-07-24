Import-Module ActiveDirectory
Add-Type -AssemblyName "System.Windows.Forms"
Add-Type -AssemblyName "System.Drawing"
[System.Windows.Forms.Application]::EnableVisualStyles()
# ----GUI----
$form = New-Object Windows.Forms.Form
$form.Text = "Keytab Generator v0.9"
$form.Size = New-Object Drawing.Size(500, 440)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
# ----Domain----
$domainLabel = New-Object Windows.Forms.Label
$domainLabel.Text = "Select Domain"
$domainLabel.Location = New-Object Drawing.Point(10, 10)
$domainLabel.Size = New-Object Drawing.Size(100, 20)
$domainComboBox = New-Object Windows.Forms.ComboBox
$domainComboBox.Location = New-Object Drawing.Point(120, 10)
$domainComboBox.Size = New-Object Drawing.Size(250, 20)
$domainComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
# Add the approved domains here in the order they should appear in the dropdown.
# Keep environment-specific domain names out of the public repository.
$domains = @(
)
if ($domains.Count -gt 0) {
    [void]$domainComboBox.Items.AddRange([object[]]$domains)
    $domainComboBox.SelectedIndex = 0
}
# ----SAMAccountName----
$samLabel = New-Object Windows.Forms.Label
$samLabel.Text = "SAMAccountName"
$samLabel.Location = New-Object Drawing.Point(10, 40)
$samLabel.Size = New-Object Drawing.Size(100, 20)
$samTextBox = New-Object Windows.Forms.TextBox
$samTextBox.MaxLength = 64
$samTextBox.Location = New-Object Drawing.Point(120, 40)
$samTextBox.Size = New-Object Drawing.Size(250, 20)
# ----Password----
$passwordLabel = New-Object Windows.Forms.Label
$passwordLabel.Text = "Password"
$passwordLabel.Location = New-Object Drawing.Point(10, 70)
$passwordLabel.Size = New-Object Drawing.Size(100, 20)
$passwordTextBox = New-Object Windows.Forms.TextBox
$passwordTextBox.MaxLength = 64
$passwordTextBox.UseSystemPasswordChar = $true
$passwordTextBox.Location = New-Object Drawing.Point(120, 70)
$passwordTextBox.Size = New-Object Drawing.Size(250, 20)
# ----Email----
$emailLabel = New-Object Windows.Forms.Label
$emailLabel.Text = "Email Address"
$emailLabel.Location = New-Object Drawing.Point(10, 100)
$emailLabel.Size = New-Object Drawing.Size(100, 20)
$emailTextBox = New-Object Windows.Forms.TextBox
$emailTextBox.Location = New-Object Drawing.Point(120, 100)
$emailTextBox.Size = New-Object Drawing.Size(250, 20)
# ----Ticket#----
$ticketLabel = New-Object Windows.Forms.Label
$ticketLabel.Text = "Ticket #"
$ticketLabel.Location = New-Object Drawing.Point(10, 130)
$ticketLabel.Size = New-Object Drawing.Size(100, 20)
$ticketTextBox = New-Object Windows.Forms.TextBox
$ticketTextBox.Location = New-Object Drawing.Point(120, 130)
$ticketTextBox.Size = New-Object Drawing.Size(250, 20)
# ----Encryption Type----
$encryptionLabel = New-Object Windows.Forms.Label
$encryptionLabel.Text = "Keytab Encryption"
$encryptionLabel.Location = New-Object Drawing.Point(10, 160)
$encryptionLabel.Size = New-Object Drawing.Size(100, 20)
$encryptionComboBox = New-Object Windows.Forms.ComboBox
$encryptionComboBox.Items.Add("AES256-SHA1")
$encryptionComboBox.SelectedIndex = 0
$encryptionComboBox.Location = New-Object Drawing.Point(120, 160)
$encryptionComboBox.Size = New-Object Drawing.Size(250, 20)
# ----Principal Type----
$principalLabel = New-Object Windows.Forms.Label
$principalLabel.Text = "Keytab Principal"
$principalLabel.Location = New-Object Drawing.Point(10, 190)
$principalLabel.Size = New-Object Drawing.Size(100, 20)
$principalComboBox = New-Object Windows.Forms.ComboBox
$principalComboBox.Items.AddRange(@("UPN", "SPN Based"))
$principalComboBox.SelectedIndex = 0
$principalComboBox.Location = New-Object Drawing.Point(120, 190)
$principalComboBox.Size = New-Object Drawing.Size(250, 20)
$spnTextBox = New-Object Windows.Forms.TextBox
$spnTextBox.MaxLength = 64
$spnTextBox.Location = New-Object Drawing.Point(120, 220)
$spnTextBox.Size = New-Object Drawing.Size(250, 20)
$spnTextBox.Visible = $false
$spnTextBox.Text = "HTTP/name.domain.com"  # no realm here... Append @REALM if needed
$principalComboBox.Add_SelectedIndexChanged({
        $spnTextBox.Visible = $principalComboBox.SelectedItem -eq "SPN Based"
    })
# --- Generate Button ---
$generateButton = New-Object Windows.Forms.Button
$generateButton.Text = "Generate Keytab"
$generateButton.Location = New-Object Drawing.Point(10, 260)
$generateButton.Size = New-Object Drawing.Size(360, 30)
$generateButton.Add_Click({
        try {
            $domain = $domainComboBox.SelectedItem
            $samAccount = $samTextBox.Text.Trim()
            $password = $passwordTextBox.Text
            $email = $emailTextBox.Text.Trim()
            $ticket = $ticketTextBox.Text.Trim()
            $encryption = $encryptionComboBox.SelectedItem
            $useSpn = ($principalComboBox.SelectedItem -eq "SPN Based")
            $spnValue = $spnTextBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($domain)) {
                throw "No domain is selected. Verify that this computer can contact Active Directory."
            }
            if ([string]::IsNullOrWhiteSpace($samAccount)) {
                throw "SAMAccountName is required."
            }
            if ([string]::IsNullOrWhiteSpace($password)) {
                throw "Password is required."
            }
            if ($useSpn -and [string]::IsNullOrWhiteSpace($spnValue)) {
                throw "SPN value is required when 'SPN Based' is selected."
            }
            # ----Confirm that the output folder exists----
            $outDir = 'C:\Temp\Keytabs'
            if (-not (Test-Path -LiteralPath $outDir)) {
                New-Item -Path $outDir -ItemType Directory -Force | Out-Null
            }
            $keytabPath = Join-Path $outDir "$samAccount.keytab"
            # ----Build the principal and PType----
            if ($useSpn) {
                $realm = $domain.ToUpper()
                if ($spnValue -notmatch '@') {
                    $principal = "$spnValue@$realm"
                }
                else {
                    $principal = $spnValue
                }
                $ptype = 'KRB5_NT_PRINCIPAL'
            }
            else {
                $principal = "$samAccount@$domain"
                $ptype = 'KRB5_NT_PRINCIPAL'
            }
            # ----Generate the keytab----
            if ($useSpn) {
                # ----Discover NetBIOS short name for the selected domain (for /mapuser)----
                $netbios = $null
                try {
                    $netbios = (Get-ADDomain -Identity $domain -ErrorAction Stop).NetBIOSName
                }
                catch { }
                if (-not $netbios) {
                    $netbios = ($domain.Split('.')[0]).ToUpper()
                }
                # ----Normalize account to SAM only----
                if ($samAccount -match '^[^\\]+\\') {
                    $samCore = $samAccount.Split('\')[-1]
                }
                elseif ($samAccount -match '@') {
                    $samCore = $samAccount.Split('@')[0]
                }
                else {
                    $samCore = $samAccount
                }
                # ----Ensure account exists----
                try {
                    $null = Get-ADUser -Server $domain -Filter "sAMAccountName -eq '$samCore'" -ErrorAction Stop | Select-Object -First 1
                }
                catch {
                    throw "The account '$samCore' was not found in $domain. Use a valid sAMAccountName."
                }
                # ----Find a DC----
                $targetHost = $null
                try {
                    $dc = Get-ADDomainController -DomainName $domain -Discover -ErrorAction Stop | Select-Object -First 1
                    if ($dc) { $targetHost = $dc.HostName }
                }
                catch {
                    try {
                        $srvRec = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction Stop | Select-Object -First 1
                        if ($srvRec -and $srvRec.NameTarget) { $targetHost = $srvRec.NameTarget.TrimEnd('.') }
                    }
                    catch { }
                }
                if (-not $targetHost) {
                    throw "Could not find a Domain Controller for $domain."
                }
                $remoteFolder = "C:\Windows\Temp"
                $remoteOutPath = Join-Path $remoteFolder ([IO.Path]::GetRandomFileName().Replace('.', '') + ".keytab")
                $mapUser = "$netbios\$samCore"
                $remoteScript = {
                    param($principal, $ptype, $encryption, $password, $remoteOutPath, $mapUser)
                    if (-not (Test-Path -LiteralPath (Split-Path -Path $remoteOutPath -Parent))) {
                        New-Item -Path (Split-Path -Path $remoteOutPath -Parent) -ItemType Directory -Force | Out-Null
                    }
                    $args = @(
                        '/princ', ('"' + $principal + '"'),
                        '/ptype', $ptype,
                        '/crypto', $encryption,
                        '/pass', ('"' + $password + '"'),
                        '/out', ('"' + $remoteOutPath + '"'),
                        '/mapuser', ('"' + $mapUser + '"')
                    )
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = 'ktpass'
                    $psi.Arguments = ($args -join ' ')
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $psi.UseShellExecute = $false
                    $p = [System.Diagnostics.Process]::Start($psi)
                    $stdout = $p.StandardOutput.ReadToEnd()
                    $stderr = $p.StandardError.ReadToEnd()
                    $p.WaitForExit()
                    $exit = $p.ExitCode
                    $result = [ordered]@{
                        ExitCode = $exit
                        StdOut   = $stdout
                        StdErr   = $stderr
                        Path     = $remoteOutPath
                        Bytes    = $null
                    }
                    if ($exit -eq 0 -and (Test-Path -LiteralPath $remoteOutPath)) {
                        try {
                            $result.Bytes = [IO.File]::ReadAllBytes($remoteOutPath)
                        }
                        catch {
                            $result.StdErr += "`nReadAllBytes failed: $($_.Exception.Message)"
                            $result.ExitCode = 9999
                        }
                    }
                    try {
                        if (Test-Path -LiteralPath $remoteOutPath) {
                            Remove-Item -LiteralPath $remoteOutPath -Force
                        }
                    }
                    catch { }
                    return $result
                }
                # ----Use current logon user's Kerberos creds (no prompt)----
                $invoke = Invoke-Command -ComputerName $targetHost `
                -Authentication Kerberos `
                -ScriptBlock $remoteScript `
                -ArgumentList $principal, $ptype, $encryption, $password, $remoteOutPath, $mapUser `
                -ErrorAction Stop
                if (-not $invoke) {
                    throw "No response from $targetHost while running ktpass."
                }
                if ($invoke.ExitCode -ne 0 -or -not $invoke.Bytes) {
                    $detail = "ExitCode: {0}`nStdOut:`n{1}`nStdErr:`n{2}" -f $invoke.ExitCode, ($invoke.StdOut | Out-String), ($invoke.StdErr | Out-String)
                    throw "ktpass failed on $targetHost.`n$detail"
                }
                [IO.File]::WriteAllBytes($keytabPath, $invoke.Bytes)
            }
            else {
                # ----UPN=run ktpass locally----
                $ktpass = 'ktpass'
                $ktArgs = @(
                    '/princ', "`"$principal`""
                    '/ptype', $ptype
                    '/crypto', $encryption
                    '/pass', "`"$password`""
                    '/out', "`"$keytabPath`""
                ) -join ' '
                $ktExit = 0
                try {
                    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $ktpass $ktArgs" -NoNewWindow -Wait -PassThru
                    $ktExit = $proc.ExitCode
                }
                catch {
                    throw "Failed to execute ktpass: $($_.Exception.Message)"
                }
                if ($ktExit -ne 0 -or -not (Test-Path -LiteralPath $keytabPath)) {
                    throw "ktpass failed (exit code: $ktExit). Keytab not created."
                }
            }
            # ----Validate with kinit----
            $validationFailed = $false
            $kinitSkipped = $false
            $kinitCmd = Get-Command kinit -ErrorAction SilentlyContinue
            if ($null -ne $kinitCmd) {
                try {
                    $testCmd = "kinit -kt `"$keytabPath`" $principal"
                    $proc2 = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $testCmd" -NoNewWindow -Wait -PassThru
                    if ($proc2.ExitCode -ne 0) {
                        $validationFailed = $true
                    }
                }
                catch {
                    $validationFailed = $true
                }
            }
            else {
                $kinitSkipped = $true
            }
            # ----IF KINIT FAILED: DO NOT SEND EMAIL, DELETE KEYTAB----
            if ($validationFailed) {
                if (Test-Path -LiteralPath $keytabPath) {
                    try {
                        Remove-Item -LiteralPath $keytabPath -Force -ErrorAction SilentlyContinue
                    }
                    catch { }
                }
                [System.Windows.Forms.MessageBox]::Show(
                    "Keytab was generated, but validation with 'kinit' FAILED.`n`n" +
                    "No email was sent and the keytab file has been deleted.",
                    "Validation Failed - Email Not Sent",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }
            # ----Email section (only runs if kinit passed OR kinit was skipped)----
            if ($email -match '^[\w\.-]+@[\w\.-]+\.\w+$') {
                try {
                    $subject = if ($ticket) { "Keytab for Ticket #$ticket" } else { "Keytab" }
                    $toList = ($email -split '[;,]' | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
                    if (-not $toList -or $toList.Count -eq 0) { throw "Email address is empty or invalid." }
                    if (-not (Test-Path -LiteralPath $keytabPath)) { throw "Attachment not found: $keytabPath" }
                    $mailParams = @{
                        To                         = $toList
                        Cc                         = ''
                        From                       = ''
                        Subject                    = $subject
                        Body                       = 'The requested Keytab is attached.'
                        SmtpServer                 = ''
                        Port                       = 25
                        Attachments                = $keytabPath
                        DeliveryNotificationOption = 'OnSuccess', 'OnFailure'
                    }
                    Send-MailMessage @mailParams -ErrorAction Stop
                    # delete local keytab after send
                    $deleted = $false
                    try {
                        Start-Sleep -Milliseconds 200
                        Remove-Item -LiteralPath $keytabPath -Force -ErrorAction Stop
                        $deleted = $true
                    }
                    catch {
                        $deleteError = $_.Exception.Message
                    }
                    $msg = "Keytab created and emailed to: $($toList -join ', ').`nCC: $($mailParams.Cc)"
                    if ($deleted) {
                        $msg += "`n`nThe local keytab file was deleted."
                    }
                    else {
                        $msg += "`n`nWarning: Could not delete the local keytab file.`nPath: $keytabPath"
                        if ($deleteError) { $msg += "`nError: $deleteError" }
                    }
                    if ($kinitSkipped) {
                        $msg += "`n`nNote: 'kinit' was not found on this system; validation was skipped."
                    }
                    [System.Windows.Forms.MessageBox]::Show(
                        $msg,
                        "Success",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                }
                catch {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Keytab created but email failed to send.`n`nError: $_`n`nPath:`n$keytabPath",
                        "Email Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                }
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Keytab created but email address is invalid or empty.`n`nPath:`n$keytabPath",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to generate keytab.`n`nError: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })
# ----Generate Command Only button----
$genCmdButton = New-Object Windows.Forms.Button
$genCmdButton.Text = "Generate Command Only"
$genCmdButton.Location = New-Object Drawing.Point(10, 340)
$genCmdButton.Size = New-Object Drawing.Size(360, 30)
$genCmdButton.Add_Click({
        try {
            $domain = $domainComboBox.SelectedItem
            $samAccount = $samTextBox.Text.Trim()
            $password = $passwordTextBox.Text
            $encryption = $encryptionComboBox.SelectedItem
            $useSpn = ($principalComboBox.SelectedItem -eq "SPN Based")
            $spnValue = $spnTextBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($domain) -or
                [string]::IsNullOrWhiteSpace($samAccount) -or
                [string]::IsNullOrWhiteSpace($password)) {
                throw "Domain, SAMAccountName, and Password are required to build the command."
            }
            $outDir = 'C:\Temp\Keytabs'
            if (-not (Test-Path -LiteralPath $outDir)) {
                New-Item -Path $outDir -ItemType Directory -Force | Out-Null
            }
            $keytabPath = Join-Path $outDir "$samAccount.keytab"
            if ($useSpn) {
                $realm = $domain.ToUpper()
                if ([string]::IsNullOrWhiteSpace($spnValue)) {
                    throw "SPN value is required when 'SPN Based' is selected."
                }
                if ($spnValue -notmatch '@') {
                    $principal = "$spnValue@$realm"
                }
                else {
                    $principal = $spnValue
                }
                $ptype = 'KRB5_NT_PRINCIPAL'
                # ----figure out NetBIOS----
                $netbios = $null
                try {
                    $netbios = (Get-ADDomain -Identity $domain -ErrorAction Stop).NetBIOSName
                }
                catch { }
                if (-not $netbios) {
                    $netbios = ($domain.Split('.')[0]).ToUpper()
                }
                if ($samAccount -match '^[^\\]+\\') {
                    $samCore = $samAccount.Split('\')[-1]
                }
                elseif ($samAccount -match '@') {
                    $samCore = $samAccount.Split('@')[0]
                }
                else {
                    $samCore = $samAccount
                }
                $mapUser = "$netbios\$samCore"
                # ----mimic the remote path the script uses----
                $remoteOutPath = "C:\Windows\Temp\$($samCore)_$([DateTime]::Now.ToString('yyyyMMddHHmmss')).keytab"
                $args = @(
                    '/princ', ('"' + $principal + '"'),
                    '/ptype', $ptype,
                    '/crypto', $encryption,
                    '/pass', '"<REDACTED>"',
                    '/out', ('"' + $remoteOutPath + '"'),
                    '/mapuser', ('"' + $mapUser + '"')
                )
                $cmd = 'ktpass ' + ($args -join ' ')
                $header = "# SPN-based command (run on a DC in $domain).`r`n# Note: This mirrors what the script runs remotely via Invoke-Command.`r`n"
            }
            else {
                $principal = "$samAccount@$domain"
                $ptype = 'KRB5_NT_PRINCIPAL'
                $args = @(
                    '/princ', ('"' + $principal + '"'),
                    '/ptype', $ptype,
                    '/crypto', $encryption,
                    '/pass', '"<REDACTED>"',
                    '/out', ('"' + $keytabPath + '"')
                )
                $cmd = 'ktpass ' + ($args -join ' ')
                $header = "# UPN-based command (runs locally).`r`n"
            }
            $outfile = [IO.Path]::GetTempFileName()
            $content = $header + $cmd + "`r`n"
            Set-Content -Path $outfile -Value $content -Encoding UTF8
            Start-Process notepad.exe $outfile
            # mark the file for later deletion when form closes
            $form.Tag = $outfile
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to generate command text.`n`nError: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })
# ----The Cancel Button----
$cancelButton = New-Object Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Location = New-Object Drawing.Point(10, 300)
$cancelButton.Size = New-Object Drawing.Size(360, 30)
$cancelButton.Add_Click({ $form.Close() })
# ----Add controls----
$form.Controls.AddRange(@(
        $domainLabel, $domainComboBox,
        $samLabel, $samTextBox,
        $passwordLabel, $passwordTextBox,
        $emailLabel, $emailTextBox,
        $ticketLabel, $ticketTextBox,
        $encryptionLabel, $encryptionComboBox,
        $principalLabel, $principalComboBox,
        $spnTextBox,
        $generateButton, $cancelButton,
        $genCmdButton
    ))
# ----Form closed: delete temp txt file (if any)----
$form.Add_FormClosed({
        try {
            if ($form.Tag -and (Test-Path -LiteralPath $form.Tag)) {
                Remove-Item -LiteralPath $form.Tag -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
    })
# Show dialog
$null = $form.ShowDialog()
