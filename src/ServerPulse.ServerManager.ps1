function New-ServerManagerBrush([string]$Color) { return New-ServerPulseThemeBrush $Color }

function New-ServerManagerButtonStyle {
    param([switch]$Accent)

    $style = [Windows.Style]::new([Windows.Controls.Button])
    $background = if ($Accent) { '#A7D948' } else { '#252C27' }
    $foreground = if ($Accent) { '#101411' } else { '#D9E0DB' }
    $border = if ($Accent) { '#91C235' } else { '#3A443D' }
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BackgroundProperty, (New-ServerManagerBrush $background)))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::ForegroundProperty, (New-ServerManagerBrush $foreground)))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BorderBrushProperty, (New-ServerManagerBrush $border)))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BorderThicknessProperty, [Windows.Thickness]::new(1)))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::OpacityProperty, 1.0))
    $disabled = [Windows.Trigger]::new()
    $disabled.Property = [Windows.Controls.Control]::IsEnabledProperty
    $disabled.Value = $false
    [void]$disabled.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BackgroundProperty, (New-ServerManagerBrush '#303732')))
    [void]$disabled.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::ForegroundProperty, (New-ServerManagerBrush '#59635D')))
    [void]$disabled.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BorderBrushProperty, (New-ServerManagerBrush '#78827C')))
    [void]$disabled.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::OpacityProperty, 0.9))
    [void]$style.Triggers.Add($disabled)
    return $style
}

function New-ServerManagerCheckBoxStyle {
    $style = [Windows.Style]::new([Windows.Controls.CheckBox])
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BackgroundProperty, (New-ServerManagerBrush '#202622')))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::ForegroundProperty, (New-ServerManagerBrush '#D9E0DB')))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BorderBrushProperty, (New-ServerManagerBrush '#69736D')))
    [void]$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BorderThicknessProperty, [Windows.Thickness]::new(1)))
    $checked = [Windows.Trigger]::new()
    $checked.Property = [Windows.Controls.Primitives.ToggleButton]::IsCheckedProperty
    $checked.Value = $true
    [void]$checked.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BackgroundProperty, (New-ServerManagerBrush '#A7D948')))
    [void]$checked.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BorderBrushProperty, (New-ServerManagerBrush '#91C235')))
    [void]$checked.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::ForegroundProperty, (New-ServerManagerBrush '#101411')))
    [void]$style.Triggers.Add($checked)
    return $style
}

function Set-ServerManagerButtonVisual {
    param([Windows.Controls.Button]$Button, [switch]$Accent)
    if ($null -eq $Button) { return }
    $Button.Style = New-ServerManagerButtonStyle -Accent:$Accent
}

function Set-ServerManagerCheckBoxVisual {
    param([Windows.Controls.CheckBox]$CheckBox)
    if ($null -eq $CheckBox) { return }
    $CheckBox.Style = New-ServerManagerCheckBoxStyle
}

function Copy-ServerPulseManagedServer {
    param($Server)
    return New-ServerPulseManagedServer -Id ([string]$Server.Id) -Label ([string]$Server.Label) -Source ([string]$Server.Source) -SshTarget ([string]$Server.SshTarget) -HostName ([string]$Server.HostName) -Port ([int]$Server.Port) -User ([string]$Server.User) -Monitored ([bool]$Server.Monitored)
}

function Get-ServerPulseCredentialState {
    param($Server, [hashtable]$SessionSecrets)
    if ($null -ne (Get-ServerPulseSessionSecret $SessionSecrets $Server.Identity)) { return Get-ServerPulseText 'manager.sessionOnly' }
    if (Test-ServerPulseStoredCredential $Server.Identity) { return Get-ServerPulseText 'manager.saved' }
    return Get-ServerPulseText 'manager.noCredential'
}

function Get-ServerPulseAuthenticationPassword {
    param($RowState, [hashtable]$SessionSecrets)
    if ($RowState.PasswordBox.Password) { return [string]$RowState.PasswordBox.Password }
    if($null-ne$RowState.Context -and $RowState.Context.PendingCredentialWrites.ContainsKey($RowState.Server.Identity)){return [string]$RowState.Context.PendingCredentialWrites[$RowState.Server.Identity].Password}
    $session = Get-ServerPulseSessionSecret $SessionSecrets $RowState.Server.Identity
    if ($null -ne $session) { return $session }
    if($null-ne$RowState.Context -and $RowState.Server.Identity-in@($RowState.Context.PendingCredentialDeletes)){return $null}
    $stored = Get-ServerPulseStoredCredential $RowState.Server.Identity
    if ($null -ne $stored) { return [string]$stored.Password }
    return $null
}

function Get-ServerManagerRememberedValidation {
    param($Context,$Server)
    if($null-eq$Context-or$null-eq$Context.ValidationStates){return $null}
    $id=[string]$Server.Id
    if(-not$Context.ValidationStates.ContainsKey($id)){return $null}
    $remembered=$Context.ValidationStates[$id]
    $mode=if([string]$remembered.Mode-in@('passwordless','password')){[string]$remembered.Mode}else{'auto'}
    $status=[string]$remembered.Status
    if($status-eq'online'-and$mode-eq'passwordless'){$status='passwordless'}
    if($status-notin@('online','passwordless','authentication_required','authentication_failed','host_key_unknown','host_key_changed','connection','error')){return $null}
    return [PSCustomObject]@{Mode=$mode;Status=$status}
}

function Save-ServerManagerRememberedValidation {
    param($Context,$RowState)
    if($null-eq$Context-or$null-eq$Context.ValidationStates){return}
    $id=[string]$RowState.Server.Id;$status=[string]$RowState.Status;$mode=[string]$RowState.AuthMode
    $storedStatus=if($status-eq'passwordless'){'online'}else{$status}
    if($Context.ValidationStates.ContainsKey($id)){
        $remembered=$Context.ValidationStates[$id]
        $remembered.Mode=$mode;$remembered.Status=$storedStatus
        if($remembered.PSObject.Properties.Name-contains'Paused'){$remembered.Paused=$storedStatus-in@('authentication_required','authentication_failed','host_key_unknown','host_key_changed')}
        if($remembered.PSObject.Properties.Name-contains'Notified'-and$storedStatus-eq'online'){$remembered.Notified=$false}
    }else{
        $Context.ValidationStates[$id]=[PSCustomObject]@{Mode=$mode;Status=$storedStatus;Paused=($storedStatus-in@('authentication_required','authentication_failed','host_key_unknown','host_key_changed'));Notified=$false}
    }
}

function Invoke-ServerPulseAuthenticationBatch {
    param([object[]]$Requests, [string]$ModulePath, [string]$AskPassPath, [int]$TimeoutMs, [string]$SshPath='ssh.exe')
    $jobs = foreach ($request in $Requests) {
        $serverJson = $request.Server | ConvertTo-Json -Compress
        Start-Job -ScriptBlock {
            param($Id,$ServerJson,$Password,$ModulePath,$AskPassPath,$TimeoutMs,$SshPath)
            $ErrorActionPreference='Stop'; . $ModulePath
            $server=$ServerJson|ConvertFrom-Json
            $result=Invoke-ServerPulseServerConnection -Server $server -Script "echo SERVERPULSE_AUTH_OK`n" -AuthMode auto -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -SshPath $SshPath
            [PSCustomObject]@{Id=$Id;Status=$result.Status;AuthMode=$result.AuthMode;Error=$result.Error;Passed=($result.Status -eq 'online' -and [string]$result.Output -match 'SERVERPULSE_AUTH_OK')}
        } -ArgumentList ([string]$request.Id),$serverJson,([string]$request.Password),$ModulePath,$AskPassPath,$TimeoutMs,$SshPath
    }
    try { return @($jobs | Receive-Job -Wait) }
    finally { foreach($job in @($jobs)){Remove-Job -Job $job -Force -ErrorAction SilentlyContinue} }
}

function Set-ServerManagerRowStatus {
    param($State,[string]$Status,[string]$Detail='')
    $State.Status=$Status
    $State.StatusText.Text=switch($Status){
        'online'{Get-ServerPulseText 'manager.online'} 'passwordless'{Get-ServerPulseText 'manager.passwordlessStatus'} 'authentication_required'{Get-ServerPulseText 'manager.authRequired'} 'authentication_failed'{Get-ServerPulseText 'manager.authFailed'}
        'host_key_unknown'{Get-ServerPulseText 'manager.hostUnknown'} 'host_key_changed'{Get-ServerPulseText 'manager.hostChanged'} 'connection'{Get-ServerPulseText 'manager.connectionUnavailable'} 'error'{Get-ServerPulseText 'manager.testFailed'} 'testing'{Get-ServerPulseText 'manager.testing'} default{Get-ServerPulseText 'manager.notVerified'}
    }
    $State.StatusText.Foreground=New-ServerManagerBrush $(switch($Status){'online'{'#A7D948'}'passwordless'{'#A7D948'}'connection'{'#E4B64B'}default{'#FF7B72'}})
    $State.StatusText.ToolTip=$Detail
    $State.PasswordPanel.Visibility=if($Status -in @('authentication_required','authentication_failed')){'Visible'}else{'Collapsed'}
    $State.Passwordless.IsChecked=($Status -eq 'passwordless')
}

function Confirm-ServerPulseHostKey {
    param([Windows.Window]$Owner,$RowState,[int]$TimeoutMs)
    try {
        $probe=Get-ServerPulseHostKeyProbe -Server $RowState.Server -TimeoutMs $TimeoutMs
        $text=Get-ServerPulseText 'manager.firstTrust' @($probe.Fingerprints -join "`n")
        $answer=[Windows.MessageBox]::Show($Owner,$text,(Get-ServerPulseText 'manager.hostUnknown'),'YesNo','Warning')
        if($answer -ne 'Yes'){return $false}
        [void](Add-ServerPulseTrustedHostKey -Lines $probe.Lines)
        return $true
    } catch { [Windows.MessageBox]::Show($Owner,$_.Exception.Message,(Get-ServerPulseText 'manager.hostChanged'),'OK','Error')|Out-Null;return $false }
}

function Complete-ServerPulseAuthenticationResult {
    param($Context,$RowState,$Result,[string]$Password)
    if($Result.Status -eq 'host_key_unknown'){
        if(Confirm-ServerPulseHostKey -Owner $Context.Window -RowState $RowState -TimeoutMs $Context.TimeoutMs){
            $retry=@(Invoke-ServerPulseAuthenticationBatch -Requests @([PSCustomObject]@{Id=$RowState.Server.Id;Server=$RowState.Server;Password=$Password}) -ModulePath $Context.ModulePath -AskPassPath $Context.AskPassPath -TimeoutMs $Context.TimeoutMs)
            if($retry.Count -gt 0){$Result=$retry[0]}
        }
    }
    if($Result.Status -eq 'host_key_changed'){
        $lookup=if([int]$RowState.Server.Port-eq22){[string]$RowState.Server.HostName}else{"[$($RowState.Server.HostName)]:$([int]$RowState.Server.Port)"}
        $command="ssh-keygen -R `"$lookup`""
        $old=@(Get-ServerPulseKnownHostFingerprints $RowState.Server)
        try{$new=@((Get-ServerPulseHostKeyProbe -Server $RowState.Server -TimeoutMs $Context.TimeoutMs).Fingerprints)}catch{$new=@((Get-ServerPulseText 'manager.fingerprintErrorTitle') + ": $($_.Exception.Message)")}
        $message=Get-ServerPulseText 'manager.fingerprintChangedMessage' @($old -join "`n",$new -join "`n",$command)
        [Windows.MessageBox]::Show($Context.Window,$message,(Get-ServerPulseText 'manager.hostChanged'),'OK','Error')|Out-Null
    }
    if($Result.Passed){
        $mode=[string]$Result.AuthMode
        if($mode -eq 'passwordless'){
            $RowState.PasswordBox.Clear();$RowState.Reveal.Text=''
            Set-ServerManagerRowStatus $RowState passwordless
        }else{
            if($RowState.PasswordBox.Password){
                if($RowState.SaveCredential.IsChecked){
                    $Context.PendingCredentialWrites[$RowState.Server.Identity]=[PSCustomObject]@{UserName=[string]$RowState.Server.User;Password=$Password}
                    [void]$Context.PendingCredentialDeletes.Remove($RowState.Server.Identity)
                    Remove-ServerPulseSessionSecret $Context.SessionSecrets $RowState.Server.Identity
                }else{
                    [void]$Context.PendingCredentialWrites.Remove($RowState.Server.Identity)
                    Set-ServerPulseSessionSecret $Context.SessionSecrets $RowState.Server.Identity $Password
                }
                $RowState.PasswordBox.Clear()
            }
            Set-ServerManagerRowStatus $RowState online
        }
        $RowState.AuthMode=$mode
        $RowState.CredentialText.Text=if($Context.PendingCredentialWrites.ContainsKey($RowState.Server.Identity)){Get-ServerPulseText 'manager.savedPending'}else{Get-ServerPulseCredentialState $RowState.Server $Context.SessionSecrets}
        $RowState.DeleteCredentialButton.Visibility=if($RowState.CredentialText.Text-eq(Get-ServerPulseText 'manager.saved')){'Visible'}else{'Collapsed'}
    }else{Set-ServerManagerRowStatus $RowState ([string]$Result.Status) ([string]$Result.Error)}
    Save-ServerManagerRememberedValidation $Context $RowState
}

function Invoke-ServerManagerRowTest {
    param($RowState,[switch]$Manual)
    $context=$RowState.Context
    if($Manual-and$null-ne$context.OnRetryRequested){& $context.OnRetryRequested ([string]$RowState.Server.Id)}
    $password=Get-ServerPulseAuthenticationPassword $RowState $context.SessionSecrets
    $RowState.TestButton.IsEnabled=$false;Set-ServerManagerRowStatus $RowState testing
    try{
        $results=@(Invoke-ServerPulseAuthenticationBatch -Requests @([PSCustomObject]@{Id=$RowState.Server.Id;Server=$RowState.Server;Password=$password}) -ModulePath $context.ModulePath -AskPassPath $context.AskPassPath -TimeoutMs $context.TimeoutMs)
        if($results.Count -eq 0){throw (Get-ServerPulseText 'manager.testFailed')}
        Complete-ServerPulseAuthenticationResult $context $RowState $results[0] $password
    }catch{Set-ServerManagerRowStatus $RowState error $_.Exception.Message}
    finally{$RowState.TestButton.IsEnabled=$true}
}

function Register-ServerManagerRowEvents {
    param($State)
    $State.TestButton.Tag=$State;$State.TestButton.Add_Click({param($sender,$eventArgs);Invoke-ServerManagerRowTest $sender.Tag -Manual})
    $State.Monitor.Tag=$State;$State.Monitor.Add_Checked({param($sender,$eventArgs);$sender.Tag.Server.Monitored=$true;if($sender.Tag.Status -eq 'unknown'){Invoke-ServerManagerRowTest $sender.Tag}})
    $State.Monitor.Add_Unchecked({param($sender,$eventArgs);$sender.Tag.Server.Monitored=$false})
    $State.Eye.Tag=$State;$State.Eye.Add_PreviewMouseLeftButtonDown({param($sender,$eventArgs);$s=$sender.Tag;$s.Reveal.Text=$s.PasswordBox.Password;$s.PasswordBox.Visibility='Collapsed';$s.Reveal.Visibility='Visible';$eventArgs.Handled=$true})
    $State.Eye.Add_PreviewMouseLeftButtonUp({param($sender,$eventArgs);$s=$sender.Tag;$s.Reveal.Text='';$s.Reveal.Visibility='Collapsed';$s.PasswordBox.Visibility='Visible';$eventArgs.Handled=$true})
    $State.Eye.Add_MouseLeave({param($sender,$eventArgs);$s=$sender.Tag;$s.Reveal.Text='';$s.Reveal.Visibility='Collapsed';$s.PasswordBox.Visibility='Visible'})
    $State.UpdateCredentialButton.Tag=$State;$State.UpdateCredentialButton.Add_Click({param($sender,$eventArgs);$s=$sender.Tag;$s.PasswordPanel.Visibility='Visible';$s.SaveCredential.IsChecked=$true;$s.PasswordBox.Focus()})
    $State.DeleteCredentialButton.Tag=$State;$State.DeleteCredentialButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag
        if(-not(Test-ServerPulseStoredCredential $s.Server.Identity)-and-not$s.Context.PendingCredentialWrites.ContainsKey($s.Server.Identity)){return}
        $affected=@($s.Context.Rows|Where-Object{$_.Server.Identity-eq$s.Server.Identity}|ForEach-Object{$_.Server.Label})-join'、'
        $answer=[Windows.MessageBox]::Show($s.Context.Window,(Get-ServerPulseText 'manager.deleteCredentialPrompt' @($s.Server.Identity,$affected)),(Get-ServerPulseText 'manager.deleteCredentialTitle'),'YesNo','Warning')
        if($answer-eq'Yes'){
            [void]$s.Context.PendingCredentialWrites.Remove($s.Server.Identity);[void]$s.Context.PendingCredentialDeletes.Add($s.Server.Identity)
        $s.CredentialText.Text=if($null-ne(Get-ServerPulseSessionSecret $s.Context.SessionSecrets $s.Server.Identity)){Get-ServerPulseText 'manager.sessionOnly'}else{Get-ServerPulseText 'manager.noCredentialPending'}
            $s.DeleteCredentialButton.Visibility='Collapsed'
        }
    })
    $State.EditButton.Tag=$State;$State.EditButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag;$edited=Show-ServerPulseManualServerDialog -Owner $s.Context.Window -Server $s.Server
        if($null-eq$edited){return};$oldIdentity=$s.Server.Identity;$identityChanged=$edited.Server.Identity-ne$oldIdentity
        if($identityChanged){
        if(((Test-ServerPulseStoredCredential $oldIdentity)-or$s.Context.PendingCredentialWrites.ContainsKey($oldIdentity))-and[Windows.MessageBox]::Show($s.Context.Window,(Get-ServerPulseText 'manager.identityChangedPrompt'),(Get-ServerPulseText 'manager.oldCredentialTitle'),'YesNo','Question')-eq'Yes'){[void]$s.Context.PendingCredentialWrites.Remove($oldIdentity);[void]$s.Context.PendingCredentialDeletes.Add($oldIdentity)}
            if(-not$edited.InheritHistory){$edited.Server.Id=[guid]::NewGuid().ToString('N')}
        }
        $s.Server=$edited.Server;$s.Monitor.Content=$s.Server.Label;$s.Monitor.IsChecked=$s.Server.Monitored
        $s.Meta.Text=("{0}  ·  {1}@{2}:{3}"-f$s.Server.SshTarget,$s.Server.User,$s.Server.HostName,$s.Server.Port)
        $s.CredentialText.Text=Get-ServerPulseCredentialState $s.Server $s.Context.SessionSecrets;$s.AuthMode='auto';Set-ServerManagerRowStatus $s unknown
        if($s.Server.Monitored){Invoke-ServerManagerRowTest $s}
    })
    $State.DeleteButton.Tag=$State;$State.DeleteButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag
        if($s.Server.Source -eq 'sshConfig'){return}
        $answer=[Windows.MessageBox]::Show($s.Context.Window,(Get-ServerPulseText 'manager.deleteServerPrompt' @($s.Server.Label)),(Get-ServerPulseText 'manager.deleteServerTitle'),'YesNo','Warning')
        if($answer -ne 'Yes'){return}
        $affected=@($s.Context.Rows|Where-Object{$_.Server.Identity-eq$s.Server.Identity}|ForEach-Object{$_.Server.Label})-join'、'
        if(((Test-ServerPulseStoredCredential $s.Server.Identity)-or$s.Context.PendingCredentialWrites.ContainsKey($s.Server.Identity)) -and [Windows.MessageBox]::Show($s.Context.Window,(Get-ServerPulseText 'manager.deleteOnApplyPrompt' @($affected)),(Get-ServerPulseText 'manager.deleteCredentialTitle'),'YesNo','Question') -eq 'Yes'){[void]$s.Context.PendingCredentialWrites.Remove($s.Server.Identity);[void]$s.Context.PendingCredentialDeletes.Add($s.Server.Identity)}
        $s.Context.Rows.Remove($s);[void]$s.Context.Panel.Children.Remove($s.Surface)
    })
    $State.AgentInjectButton.Tag=$State;$State.AgentInjectButton.Add_Click({param($sender,$eventArgs);$s=$sender.Tag;Invoke-ServerManagerAgentOperation $s.Context $s inject})
    $State.AgentStopButton.Tag=$State;$State.AgentStopButton.Add_Click({param($sender,$eventArgs);$s=$sender.Tag;Invoke-ServerManagerAgentOperation $s.Context $s stop})
    $State.AgentRestartButton.Tag=$State;$State.AgentRestartButton.Add_Click({param($sender,$eventArgs);$s=$sender.Tag;Invoke-ServerManagerAgentOperation $s.Context $s restart})
    $State.AgentConfigButton.Tag=$State;$State.AgentConfigButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag
        $entry=Get-ServerPulseAgentServerEntry $s.Context.AgentState ([string]$s.Server.Id)
        $interval=if($null-ne$entry){[int]$entry.IntervalSeconds}else{5}
        $retention=if($null-ne$entry){[int]$entry.RetentionDays}else{30}
        $restore=if($null-ne$entry){[bool]$entry.AutoRestoreOnStartup}else{$false}
        $choice=Show-ServerPulseAgentConfigDialog -Owner $s.Context.Window -IntervalSeconds $interval -RetentionDays $retention -AutoRestoreOnStartup $restore
        if($null-eq$choice){return}
        Set-ServerPulseAgentServerEntry -State $s.Context.AgentState -Id ([string]$s.Server.Id) -IntervalSeconds $choice.IntervalSeconds -RetentionDays $choice.RetentionDays -AutoRestoreOnStartup $choice.AutoRestoreOnStartup
        if(-not[string]::IsNullOrWhiteSpace($s.Context.AgentStatePath)){try{Save-ServerPulseAgentState $s.Context.AgentStatePath $s.Context.AgentState}catch{}}
        Invoke-ServerManagerAgentOperation $s.Context $s update-config
    })
    $State.AgentMergeButton.Tag=$State;$State.AgentMergeButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag
        $choice=Show-ServerPulseAgentMergeDialog -Owner $s.Context.Window
        if($null-eq$choice){return}
        Invoke-ServerManagerAgentOperation $s.Context $s merge -CleanMerged $choice.CleanMerged
    })
    $State.AgentUninstallButton.Tag=$State;$State.AgentUninstallButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag
        if([Windows.MessageBox]::Show($s.Context.Window,(Get-ServerPulseText 'agent.uninstallPrompt' @($s.Server.Label)),(Get-ServerPulseText 'agent.uninstallTitle'),'YesNo','Warning')-eq'Yes'){Invoke-ServerManagerAgentOperation $s.Context $s uninstall}
    })
}

function New-ServerManagerRow {
    param($Context,$Server)
    $surface=[Windows.Controls.Border]::new();$surface.Background=New-ServerManagerBrush '#151A17';$surface.BorderBrush=New-ServerManagerBrush '#303731';$surface.BorderThickness=1;$surface.CornerRadius=7;$surface.Padding=10;$surface.Margin='0,0,0,8'
    $stack=[Windows.Controls.StackPanel]::new();$surface.Child=$stack
    $header=[Windows.Controls.Grid]::new();[void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$auto=[Windows.Controls.ColumnDefinition]::new();$auto.Width='Auto';[void]$header.ColumnDefinitions.Add($auto)
    $monitor=[Windows.Controls.CheckBox]::new();$monitor.Content=$Server.Label;$monitor.IsChecked=[bool]$Server.Monitored;$monitor.Foreground=New-ServerManagerBrush '#EDF2EE';$monitor.FontSize=13;$monitor.FontWeight='SemiBold';Set-ServerManagerCheckBoxVisual $monitor
    $status=[Windows.Controls.TextBlock]::new();$status.Text=Get-ServerPulseText 'manager.notVerified';$status.Foreground=New-ServerManagerBrush '#7A857E';$status.FontSize=9;$status.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($status,1)
    [void]$header.Children.Add($monitor);[void]$header.Children.Add($status);[void]$stack.Children.Add($header)
    $meta=[Windows.Controls.TextBlock]::new();$meta.Text=("{0}  ·  {1}@{2}:{3}" -f $Server.SshTarget,$Server.User,$Server.HostName,$Server.Port);$meta.Foreground=New-ServerManagerBrush '#78827C';$meta.FontSize=9;$meta.Margin='22,4,0,6';[void]$stack.Children.Add($meta)
    $tools=[Windows.Controls.StackPanel]::new();$tools.Orientation='Horizontal';$tools.Margin='22,0,0,4'
    $passwordless=[Windows.Controls.CheckBox]::new();$passwordless.Content=Get-ServerPulseText 'manager.passwordless';$passwordless.IsHitTestVisible=$false;$passwordless.Focusable=$false;$passwordless.Foreground=New-ServerManagerBrush '#AAB3AD';$passwordless.FontSize=9;$passwordless.Margin='0,0,4,0';Set-ServerManagerCheckBoxVisual $passwordless
    $info=[Windows.Controls.Border]::new();$info.Width=16;$info.Height=16;$info.CornerRadius=8;$info.Background=New-ServerManagerBrush '#29312B';$info.Margin='0,0,12,0';$info.Cursor='Help';$mark=[Windows.Controls.TextBlock]::new();$mark.Text='!';$mark.Foreground=New-ServerManagerBrush '#E4B64B';$mark.HorizontalAlignment='Center';$mark.VerticalAlignment='Center';$mark.FontWeight='Bold';$info.Child=$mark
    $info.ToolTip=Get-ServerPulseText 'manager.passwordlessTip'
    $credential=[Windows.Controls.TextBlock]::new();$credential.Text=Get-ServerPulseCredentialState $Server $Context.SessionSecrets;$credential.Foreground=New-ServerManagerBrush '#87928B';$credential.FontSize=9;$credential.VerticalAlignment='Center'
    $updateCredential=[Windows.Controls.Button]::new();$updateCredential.Content=Get-ServerPulseText 'manager.updatePassword';$updateCredential.Margin='7,0,0,0';$updateCredential.Padding='7,2';Set-ServerManagerButtonVisual $updateCredential
    $deleteCredential=[Windows.Controls.Button]::new();$deleteCredential.Content=Get-ServerPulseText 'manager.deleteCredential';$deleteCredential.Margin='5,0,0,0';$deleteCredential.Padding='7,2';$deleteCredential.Visibility=if($credential.Text-eq(Get-ServerPulseText 'manager.saved')){'Visible'}else{'Collapsed'};Set-ServerManagerButtonVisual $deleteCredential
    $test=[Windows.Controls.Button]::new();$test.Content=Get-ServerPulseText 'manager.recheck';$test.Margin='12,0,0,0';$test.Padding='8,2';Set-ServerManagerButtonVisual $test
    $edit=[Windows.Controls.Button]::new();$edit.Content=Get-ServerPulseText 'manager.edit';$edit.Margin='6,0,0,0';$edit.Padding='8,2';$edit.Visibility=if($Server.Source -eq 'sshConfig'){'Collapsed'}else{'Visible'};Set-ServerManagerButtonVisual $edit
    $delete=[Windows.Controls.Button]::new();$delete.Content=Get-ServerPulseText 'manager.delete';$delete.Margin='6,0,0,0';$delete.Padding='8,2';$delete.Visibility=if($Server.Source -eq 'sshConfig'){'Collapsed'}else{'Visible'};Set-ServerManagerButtonVisual $delete
    foreach($control in @($passwordless,$info,$credential,$updateCredential,$deleteCredential,$test,$edit,$delete)){[void]$tools.Children.Add($control)};[void]$stack.Children.Add($tools)
    $passwordPanel=[Windows.Controls.StackPanel]::new();$passwordPanel.Margin='22,5,0,2';$passwordPanel.Visibility='Collapsed'
    $passwordLine=[Windows.Controls.Grid]::new();[void]$passwordLine.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$eyeColumn=[Windows.Controls.ColumnDefinition]::new();$eyeColumn.Width='Auto';[void]$passwordLine.ColumnDefinitions.Add($eyeColumn)
    $password=[Windows.Controls.PasswordBox]::new();$password.Height=26;$password.Padding='6,3';$password.Background=New-ServerManagerBrush '#202622';$password.Foreground=New-ServerManagerBrush '#E7ECE8';$password.BorderBrush=New-ServerManagerBrush '#3A443D'
    $reveal=[Windows.Controls.TextBox]::new();$reveal.Height=26;$reveal.Padding='6,3';$reveal.IsReadOnly=$true;$reveal.Visibility='Collapsed';$reveal.Background=$password.Background;$reveal.Foreground=$password.Foreground
    $eye=[Windows.Controls.Button]::new();$eye.Content=Get-ServerPulseText 'manager.reveal';$eye.Margin='6,0,0,0';$eye.Padding='7,2';Set-ServerManagerButtonVisual $eye;[Windows.Controls.Grid]::SetColumn($eye,1)
    [void]$passwordLine.Children.Add($password);[void]$passwordLine.Children.Add($reveal);[void]$passwordLine.Children.Add($eye);[void]$passwordPanel.Children.Add($passwordLine)
    $save=[Windows.Controls.CheckBox]::new();$save.Content=Get-ServerPulseText 'manager.saveCredential';$save.IsChecked=$false;$save.Foreground=New-ServerManagerBrush '#AAB3AD';$save.FontSize=9;$save.Margin='0,6,0,0';Set-ServerManagerCheckBoxVisual $save;[void]$passwordPanel.Children.Add($save);[void]$stack.Children.Add($passwordPanel)
    $agentLine=[Windows.Controls.StackPanel]::new();$agentLine.Orientation='Horizontal';$agentLine.Margin='22,4,0,0'
    $agentBadge=[Windows.Controls.TextBlock]::new();$agentBadge.VerticalAlignment='Center';$agentBadge.FontSize=9;$agentBadge.Margin='0,0,10,0';$agentBadge.Foreground=New-ServerManagerBrush '#657069'
    $agentInject=[Windows.Controls.Button]::new();$agentInject.Content=Get-ServerPulseText 'agent.inject';$agentInject.Padding='7,2';Set-ServerManagerButtonVisual $agentInject
    $agentStop=[Windows.Controls.Button]::new();$agentStop.Content=Get-ServerPulseText 'agent.stop';$agentStop.Padding='7,2';$agentStop.Margin='5,0,0,0';Set-ServerManagerButtonVisual $agentStop
    $agentRestart=[Windows.Controls.Button]::new();$agentRestart.Content=Get-ServerPulseText 'agent.restart';$agentRestart.Padding='7,2';$agentRestart.Margin='5,0,0,0';Set-ServerManagerButtonVisual $agentRestart
    $agentConfig=[Windows.Controls.Button]::new();$agentConfig.Content=Get-ServerPulseText 'agent.config';$agentConfig.Padding='7,2';$agentConfig.Margin='5,0,0,0';Set-ServerManagerButtonVisual $agentConfig
    $agentMerge=[Windows.Controls.Button]::new();$agentMerge.Content=Get-ServerPulseText 'agent.merge';$agentMerge.Padding='7,2';$agentMerge.Margin='5,0,0,0';Set-ServerManagerButtonVisual $agentMerge
    $agentUninstall=[Windows.Controls.Button]::new();$agentUninstall.Content=Get-ServerPulseText 'agent.uninstall';$agentUninstall.Padding='7,2';$agentUninstall.Margin='5,0,0,0';Set-ServerManagerButtonVisual $agentUninstall
    foreach($control in @($agentBadge,$agentInject,$agentStop,$agentRestart,$agentConfig,$agentMerge,$agentUninstall)){[void]$agentLine.Children.Add($control)}
    [void]$stack.Children.Add($agentLine)
    $state=[PSCustomObject]@{Context=$Context;Server=$Server;Surface=$surface;Monitor=$monitor;Meta=$meta;StatusText=$status;Passwordless=$passwordless;CredentialText=$credential;UpdateCredentialButton=$updateCredential;DeleteCredentialButton=$deleteCredential;TestButton=$test;EditButton=$edit;DeleteButton=$delete;PasswordPanel=$passwordPanel;PasswordBox=$password;Reveal=$reveal;Eye=$eye;SaveCredential=$save;Status='unknown';AuthMode='auto';AgentBadge=$agentBadge;AgentInjectButton=$agentInject;AgentStopButton=$agentStop;AgentRestartButton=$agentRestart;AgentConfigButton=$agentConfig;AgentMergeButton=$agentMerge;AgentUninstallButton=$agentUninstall;AgentStatus='unknown';AgentBusy=$false}
    Register-ServerManagerRowEvents $state
    $remembered=Get-ServerManagerRememberedValidation $Context $Server
    if($null-ne$remembered){$state.AuthMode=[string]$remembered.Mode;Set-ServerManagerRowStatus $state ([string]$remembered.Status)}
    $agentEntry=Get-ServerPulseAgentServerEntry $Context.AgentState ([string]$Server.Id)
    $agentInitialStatus=if($null-ne$agentEntry){if([string]$agentEntry.LastStatus-in@('running','stale','stopped','not_installed')){[string]$agentEntry.LastStatus}else{'unknown'}}else{'not_configured'}
    Set-ServerManagerAgentStatus $state $agentInitialStatus
    return $state
}

function Update-ServerManagerLanguage {
    param([Windows.Window]$Window)
    if ($null -eq $Window -or $null -eq $Window.Tag) { return }
    $context = $Window.Tag
    $Window.Title = Get-ServerPulseText 'manager.title'
    if ($context.PSObject.Properties.Name -contains 'Intro') { $context.Intro.Text = Get-ServerPulseText 'manager.intro' }
    if ($context.PSObject.Properties.Name -contains 'AddButton') { $context.AddButton.Content = Get-ServerPulseText 'manager.add'; $context.ApplyButton.Content = Get-ServerPulseText 'manager.apply'; $context.CancelButton.Content = Get-ServerPulseText 'manager.cancel' }
    $context.DiscoveryStatus.Text = switch ([string]$context.DiscoveryState) { 'discovering' { Get-ServerPulseText 'manager.discovering' } 'discovered' { Get-ServerPulseText 'manager.discovered' @([int]$context.DiscoveryCount) } 'none' { Get-ServerPulseText 'manager.noNew' } 'failed' { Get-ServerPulseText 'manager.discoveryFailed' } default { Get-ServerPulseText 'manager.waitingDiscovery' } }
    foreach ($row in @($context.Rows)) {
        $row.Passwordless.Content = Get-ServerPulseText 'manager.passwordless'
        $row.UpdateCredentialButton.Content = Get-ServerPulseText 'manager.updatePassword'
        $row.DeleteCredentialButton.Content = Get-ServerPulseText 'manager.deleteCredential'
        $row.TestButton.Content = Get-ServerPulseText 'manager.recheck'
        $row.EditButton.Content = Get-ServerPulseText 'manager.edit'
        $row.DeleteButton.Content = Get-ServerPulseText 'manager.delete'
        $row.Eye.Content = Get-ServerPulseText 'manager.reveal'
        $row.SaveCredential.Content = Get-ServerPulseText 'manager.saveCredential'
        $row.AgentInjectButton.Content = Get-ServerPulseText 'agent.inject'
        $row.AgentStopButton.Content = Get-ServerPulseText 'agent.stop'
        $row.AgentRestartButton.Content = Get-ServerPulseText 'agent.restart'
        $row.AgentConfigButton.Content = Get-ServerPulseText 'agent.config'
        $row.AgentMergeButton.Content = Get-ServerPulseText 'agent.merge'
        $row.AgentUninstallButton.Content = Get-ServerPulseText 'agent.uninstall'
        $info = $row.Passwordless.Parent.Children | Where-Object { $_ -is [Windows.Controls.Border] } | Select-Object -First 1
        if ($null -ne $info) { $info.ToolTip = Get-ServerPulseText 'manager.passwordlessTip' }
        Set-ServerManagerRowStatus $row ([string]$row.Status) $row.StatusText.ToolTip
        Set-ServerManagerAgentStatus $row ([string]$row.AgentStatus) $row.AgentBadge.ToolTip
        $row.CredentialText.Text = if ($context.PendingCredentialWrites.ContainsKey($row.Server.Identity)) { Get-ServerPulseText 'manager.savedPending' } else { Get-ServerPulseCredentialState $row.Server $context.SessionSecrets }
        $row.DeleteCredentialButton.Visibility = if ($row.CredentialText.Text -eq (Get-ServerPulseText 'manager.saved')) { 'Visible' } else { 'Collapsed' }
    }
    if ($context.PSObject.Properties.Name -contains 'MergeAllButton') { $context.MergeAllButton.Content = Get-ServerPulseText 'agent.mergeAll' }
}

function Start-ServerManagerCandidateDiscovery {
    param($Context)
    $known=@{};foreach($row in @($Context.Rows)){$known[[string]$row.Server.SshTarget]=$true}
    $context.KnownTargets=$known
    $context.DiscoveryState='discovering'; $context.DiscoveryCount=0; $context.DiscoveryStatus.Text=Get-ServerPulseText 'manager.discovering'
    $context.DiscoveryPowerShell=[PowerShell]::Create()
    $context.DiscoveryPowerShell.AddScript({param($ModulePath);$ErrorActionPreference='Stop';. $ModulePath;$results=foreach($alias in @(Get-ServerPulseSshConfigAliases)){try{$resolved=Get-ServerPulseSshResolvedTarget $alias;[PSCustomObject]@{Alias=$alias;HostName=$resolved.HostName;Port=$resolved.Port;User=$resolved.User}}catch{}};return @($results)}).AddArgument($Context.SshModulePath)|Out-Null
    $context.DiscoveryAsync=$context.DiscoveryPowerShell.BeginInvoke()
    $context.DiscoveryTimer=[Windows.Threading.DispatcherTimer]::new();$context.DiscoveryTimer.Interval=[TimeSpan]::FromMilliseconds(100);$context.DiscoveryTimer.Tag=$context
    $context.DiscoveryTimer.Add_Tick({param($sender,$eventArgs);$ctx=$sender.Tag;if(-not$ctx.DiscoveryAsync.IsCompleted){return};$sender.Stop();try{$found=@($ctx.DiscoveryPowerShell.EndInvoke($ctx.DiscoveryAsync));foreach($resolved in $found){if($ctx.KnownTargets.ContainsKey([string]$resolved.Alias)){continue};$server=New-ServerPulseManagedServer -Label ([string]$resolved.Alias) -Source sshConfig -SshTarget ([string]$resolved.Alias) -HostName ([string]$resolved.HostName) -Port ([int]$resolved.Port) -User ([string]$resolved.User) -Monitored $false;$row=New-ServerManagerRow $ctx $server;[void]$ctx.Rows.Add($row);[void]$ctx.Panel.Children.Add($row.Surface);$ctx.KnownTargets[[string]$resolved.Alias]=$true};$ctx.DiscoveryState=if($found.Count){'discovered'}else{'none'};$ctx.DiscoveryCount=$found.Count;$ctx.DiscoveryStatus.Text=if($found.Count){Get-ServerPulseText 'manager.discovered' @($found.Count)}else{Get-ServerPulseText 'manager.noNew'}}catch{$ctx.DiscoveryState='failed';$ctx.DiscoveryCount=0;$ctx.DiscoveryStatus.Text=Get-ServerPulseText 'manager.discoveryFailed'}finally{$ctx.DiscoveryPowerShell.Dispose();$ctx.DiscoveryPowerShell=$null;$ctx.DiscoveryAsync=$null}})
    $context.DiscoveryTimer.Start()
}

function Stop-ServerManagerCandidateDiscovery {
    param($Context)
    if($null-ne$Context.DiscoveryTimer){$Context.DiscoveryTimer.Stop()}
    $shell=$Context.DiscoveryPowerShell;$Context.DiscoveryPowerShell=$null;$Context.DiscoveryAsync=$null
    if($null-eq$shell){return}
    if($shell.InvocationStateInfo.State-in@('Running','Stopping')){
        try{[void]$shell.BeginStop({param($asyncResult);$worker=[PowerShell]$asyncResult.AsyncState;try{$worker.EndStop($asyncResult)}catch{}finally{$worker.Dispose()}},$shell)}catch{$shell.Dispose()}
    }else{$shell.Dispose()}
}

# Background worker for server-side agent operations. Runs in its own
# runspace with the agent/SSH/sample modules dot-sourced; returns a uniform
# envelope consumed by Complete-ServerManagerAgentOperation.
$script:ServerManagerAgentOpScript = @'
param($ServerJson,$Action,$Password,$IntervalSeconds,$RetentionDays,$CursorUtc,$CleanMerged,$KnownIdsJson,$HistoryDirectory,$AgentModulePath,$SshModulePath,$SampleModulePath,$StorageModulePath,$CoreModulePath,$AskPassPath,$TimeoutMs)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. $CoreModulePath
. $StorageModulePath
. $AgentModulePath
. $SshModulePath
. $SampleModulePath
$server = $ServerJson | ConvertFrom-Json
switch ($Action) {
    'status' {
        $result = Get-ServerPulseAgentStatus -Server $server -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -IntervalSeconds $IntervalSeconds
        return [PSCustomObject]@{ Kind='status'; Status=$result.Status; Error=$result.Error; Pid=$result.Pid; HeartbeatAgeSeconds=$result.HeartbeatAgeSeconds }
    }
    'merge' {
        $knownIds = @($KnownIdsJson | ConvertFrom-Json)
        $result = Merge-ServerPulseAgentRecords -Server $server -HistoryDirectory $HistoryDirectory -KnownServerIds $knownIds -CursorUtc $CursorUtc -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -CleanMerged:$CleanMerged
        return [PSCustomObject]@{ Kind='merge'; Summary=$result }
    }
    default {
        $result = Invoke-ServerPulseAgentControl -Server $server -Action $Action -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -IntervalSeconds $IntervalSeconds -RetentionDays $RetentionDays
        return [PSCustomObject]@{ Kind='control'; Result=$result }
    }
}
'@

function Set-ServerManagerAgentStatus {
    param($RowState,[string]$Status,[string]$Detail='')
    $RowState.AgentStatus=$Status
    $RowState.AgentBadge.Text=switch($Status){
        'running'{Get-ServerPulseText 'agent.status.running'}'stale'{Get-ServerPulseText 'agent.status.stale'}'stopped'{Get-ServerPulseText 'agent.status.stopped'}
        'not_installed'{Get-ServerPulseText 'agent.status.notInstalled'}'checking'{Get-ServerPulseText 'agent.status.checking'}'not_configured'{Get-ServerPulseText 'agent.notConfigured'}
        default{Get-ServerPulseText 'agent.status.unknown'}
    }
    $RowState.AgentBadge.Foreground=New-ServerManagerBrush $(switch($Status){
        'running'{'#A7D948'}'stale'{'#E4B64B'}'stopped'{'#FF7B72'}'error'{'#FF7B72'}'not_configured'{'#657069'}default{'#7A857E'}
    })
    $RowState.AgentBadge.ToolTip=$Detail
}

function Set-ServerManagerAgentBusy {
    param($RowState,[bool]$Busy)
    $RowState.AgentBusy=$Busy
    foreach($button in @($RowState.AgentInjectButton,$RowState.AgentStopButton,$RowState.AgentRestartButton,$RowState.AgentConfigButton,$RowState.AgentMergeButton,$RowState.AgentUninstallButton)){
        if($null-ne$button){$button.IsEnabled=-not$Busy}
    }
}

function Invoke-ServerManagerAgentOperation {
    param($Context,$RowState,[ValidateSet('status','inject','stop','restart','update-config','uninstall','merge')][string]$Action,[bool]$CleanMerged=$false)
    if($null-eq$Context-or$null-eq$RowState){return}
    if($RowState.AgentBusy-and$Action-ne'status'){return}
    if($Action-eq'merge'-and[string]::IsNullOrWhiteSpace($Context.HistoryDirectory)){
        [Windows.MessageBox]::Show($Context.Window,(Get-ServerPulseText 'agent.mergeError' @('History directory unavailable')),(Get-ServerPulseText 'agent.mergeTitle'),'OK','Error')|Out-Null
        return
    }
    $serverJson=$RowState.Server|ConvertTo-Json -Compress
    $password=Get-ServerPulseAuthenticationPassword $RowState $Context.SessionSecrets
    $entry=Get-ServerPulseAgentServerEntry $Context.AgentState ([string]$RowState.Server.Id)
    # Every non-status operation works with local config defaults; record the
    # entry so an injected agent survives reopening the manager.
    if($null-eq$entry-and$Action-ne'status'){
        $entry=Set-ServerPulseAgentServerEntry -State $Context.AgentState -Id ([string]$RowState.Server.Id)
    }
    $interval=if($null-ne$entry){[int]$entry.IntervalSeconds}else{5}
    $retention=if($null-ne$entry){[int]$entry.RetentionDays}else{30}
    $cursor=if($null-ne$entry){[string]$entry.MergeCursorUtc}else{$null}
    $knownIds=@($Context.Rows|ForEach-Object{[string]$_.Server.Id}|Sort-Object -Unique)
    $knownIdsJson=$knownIds|ConvertTo-Json -Compress
    $shell=[PowerShell]::Create()
    [void]$shell.AddScript($script:ServerManagerAgentOpScript)
    [void]$shell.AddArgument($serverJson).AddArgument($Action).AddArgument($password).AddArgument($interval).AddArgument($retention).AddArgument($cursor).AddArgument($CleanMerged).AddArgument($knownIdsJson).AddArgument($Context.HistoryDirectory).AddArgument($Context.AgentModulePath).AddArgument($Context.ModulePath).AddArgument($Context.SampleModulePath).AddArgument($Context.StorageModulePath).AddArgument($Context.CoreModulePath).AddArgument($Context.AskPassPath).AddArgument($Context.TimeoutMs)
    $async=$shell.BeginInvoke()
    $Context.AgentOps.Add([PSCustomObject]@{RowState=$RowState;Shell=$shell;Async=$async;Action=$Action})
    if($Action-ne'status'){Set-ServerManagerAgentBusy $RowState $true}
    Start-ServerManagerAgentOpTimer $Context
}

function Start-ServerManagerAgentOpTimer {
    param($Context)
    if($null-ne$Context.AgentOpTimer-and$Context.AgentOpTimer.IsEnabled){return}
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100);$timer.Tag=$Context
    $timer.Add_Tick({param($sender,$eventArgs)
        $ctx=$sender.Tag
        $finished=@($ctx.AgentOps|Where-Object{$_.Async.IsCompleted})
        foreach($op in $finished){
            $ctx.AgentOps.Remove($op)
            try{
                $output=@($op.Shell.EndInvoke($op.Async))
                $payload=if($output.Count-gt0){$output[0]}else{$null}
                Complete-ServerManagerAgentOperation $ctx $op $payload
            }catch{
                Set-ServerManagerAgentStatus $op.RowState error $_.Exception.Message
                Set-ServerManagerAgentBusy $op.RowState $false
            }finally{$op.Shell.Dispose()}
        }
        if($ctx.AgentOps.Count-eq0){$sender.Stop()}
    })
    $Context.AgentOpTimer=$timer;$timer.Start()
}

function Complete-ServerManagerAgentOperation {
    param($Context,$Op,$Payload)
    $row=$Op.RowState
    $entry=Get-ServerPulseAgentServerEntry $Context.AgentState ([string]$row.Server.Id)
    switch($Op.Action){
        'status'{
            $status=[string]$Payload.Status
            if($status-eq'error'){
                if($null-ne$entry){Update-ServerPulseAgentStatusState $entry $Payload;Set-ServerManagerAgentStatus $row error ([string]$Payload.Error)}
                else{Set-ServerManagerAgentStatus $row not_configured}
            }
            elseif($null-eq$entry){
                # A server can already run an agent without a local config
                # entry (e.g. injected before the entry was written). Adopt
                # it so the status survives reopening the manager.
                if($status-in@('running','stale','stopped')){
                    $entry=Set-ServerPulseAgentServerEntry -State $Context.AgentState -Id ([string]$row.Server.Id)
                    Update-ServerPulseAgentStatusState $entry $Payload
                    Set-ServerManagerAgentStatus $row $status
                }else{
                    Set-ServerManagerAgentStatus $row not_configured
                }
            }
            else{
                Update-ServerPulseAgentStatusState $entry $Payload
                Set-ServerManagerAgentStatus $row $status
            }
        }
        'merge'{
            $summary=$Payload.Summary
            if($null-ne$summary-and-not[string]$summary.Error){
                if($null-ne$entry){
                    $entry.MergeCursorUtc=if($null-ne$summary.MaxUtcMinute){$summary.MaxUtcMinute.ToString('yyyy-MM-ddTHH:mm')}else{$entry.MergeCursorUtc}
                    $entry.LastMergeAt=[DateTime]::UtcNow.ToString('o')
                    $entry.LastMergeSummary=$summary|Select-Object PulledLines,Added,Updated,Skipped,DroppedUnknown,CorruptLines,CleanedFiles,DurationMs
                }
                $text=Get-ServerPulseText 'agent.mergeSummary' @([int]$summary.PulledLines,[int]$summary.Added,[int]$summary.Updated,[int]$summary.Skipped,[int]$summary.DroppedUnknown,[int]$summary.CorruptLines,[int]$summary.CleanedFiles,[int]$summary.DurationMs)
                [Windows.MessageBox]::Show($Context.Window,$text,(Get-ServerPulseText 'agent.mergeResult'),'OK','Information')|Out-Null
                Invoke-ServerManagerAgentOperation $Context $row status
            }else{
                $errorText=if($null-ne$summary){[string]$summary.Error}else{(Get-ServerPulseText 'agent.mergeNothing')}
                [Windows.MessageBox]::Show($Context.Window,(Get-ServerPulseText 'agent.mergeError' @($errorText)),(Get-ServerPulseText 'agent.mergeTitle'),'OK','Error')|Out-Null
                Invoke-ServerManagerAgentOperation $Context $row status
            }
        }
        default{
            $result=$Payload.Result
            $message=switch([string]$result.Result){
                'started'{Get-ServerPulseText 'agent.injectStarted'}
                'already_running'{Get-ServerPulseText 'agent.injectAlready'}
                'stopped'{Get-ServerPulseText 'agent.stopDone'}
                'config_updated'{Get-ServerPulseText 'agent.configDone'}
                'uninstalled'{Get-ServerPulseText 'agent.uninstallDone'}
                default{Get-ServerPulseText 'agent.opError' @([string]$result.Result)}
            }
            if([string]$result.Result-eq'error'){Set-ServerManagerAgentStatus $row error ([string]$result.Error)}
            [Windows.MessageBox]::Show($Context.Window,$message,(Get-ServerPulseText 'agent.title'),'OK','Information')|Out-Null
            Invoke-ServerManagerAgentOperation $Context $row status
        }
    }
    Set-ServerManagerAgentBusy $row $false
    if(-not[string]::IsNullOrWhiteSpace($Context.AgentStatePath)){
        try{Save-ServerPulseAgentState $Context.AgentStatePath $Context.AgentState}catch{}
    }
}

function Stop-ServerManagerAgentOperations {
    param($Context)
    if($null-ne$Context.AgentOpTimer){$Context.AgentOpTimer.Stop();$Context.AgentOpTimer=$null}
    foreach($op in @($Context.AgentOps)){
        $Context.AgentOps.Remove($op)
        if($op.Shell.InvocationStateInfo.State-in@('Running','Stopping')){
            try{[void]$op.Shell.BeginStop({param($asyncResult);$worker=[PowerShell]$asyncResult.AsyncState;try{$worker.EndStop($asyncResult)}catch{}finally{$worker.Dispose()}},$op.Shell)}catch{$op.Shell.Dispose()}
        }else{$op.Shell.Dispose()}
    }
}

function Show-ServerPulseAgentConfigDialog {
    param([Windows.Window]$Owner,[int]$IntervalSeconds=5,[int]$RetentionDays=30,[bool]$AutoRestoreOnStartup=$false)
    $dialog=[Windows.Window]::new();$dialog.Title=Get-ServerPulseText 'agent.configTitle';$dialog.Width=380;$dialog.Height=300;$dialog.Owner=$Owner
    $dialog.WindowStartupLocation='CenterOwner';$dialog.ShowInTaskbar=$false;$dialog.ResizeMode='NoResize'
    $dialog.Background=New-ServerManagerBrush '#101411';$dialog.Foreground=New-ServerManagerBrush '#E7ECE8';$dialog.FontFamily='Microsoft YaHei UI'
    $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=18;$dialog.Content=$panel
    $intervalLabel=[Windows.Controls.TextBlock]::new();$intervalLabel.Text=Get-ServerPulseText 'agent.interval';$intervalLabel.Margin='0,4,0,3';[void]$panel.Children.Add($intervalLabel)
    $intervalBox=[Windows.Controls.TextBox]::new();$intervalBox.Height=28;$intervalBox.Padding='6,3';$intervalBox.Text=[string]$IntervalSeconds;[void]$panel.Children.Add($intervalBox)
    $retentionLabel=[Windows.Controls.TextBlock]::new();$retentionLabel.Text=Get-ServerPulseText 'agent.retention';$retentionLabel.Margin='0,10,0,3';[void]$panel.Children.Add($retentionLabel)
    $retentionBox=[Windows.Controls.TextBox]::new();$retentionBox.Height=28;$retentionBox.Padding='6,3';$retentionBox.Text=[string]$RetentionDays;[void]$panel.Children.Add($retentionBox)
    $restore=[Windows.Controls.CheckBox]::new();$restore.Content=Get-ServerPulseText 'agent.autoRestore';$restore.IsChecked=$AutoRestoreOnStartup;$restore.Margin='0,12,0,0';$restore.Foreground=New-ServerManagerBrush '#D9E0DB';Set-ServerManagerCheckBoxVisual $restore;[void]$panel.Children.Add($restore)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.Margin='0,18,0,0'
    $ok=[Windows.Controls.Button]::new();$ok.Content=Get-ServerPulseText 'agent.save';$ok.Padding='14,4';Set-ServerManagerButtonVisual $ok -Accent
    $cancel=[Windows.Controls.Button]::new();$cancel.Content=Get-ServerPulseText 'manager.cancel';$cancel.Padding='14,4';$cancel.Margin='8,0,0,0';Set-ServerManagerButtonVisual $cancel
    [void]$buttons.Children.Add($ok);[void]$buttons.Children.Add($cancel);[void]$panel.Children.Add($buttons)
    $dialog.Tag=[PSCustomObject]@{IntervalBox=$intervalBox;RetentionBox=$retentionBox;Restore=$restore;Result=$null}
    $ok.Tag=$dialog;$ok.Add_Click({param($sender,$eventArgs)
        $w=$sender.Tag
        try{
            $i=0;$r=0
            if(-not[int]::TryParse($w.Tag.IntervalBox.Text,[ref]$i)-or$i-lt1-or$i-gt3600){throw (Get-ServerPulseText 'agent.interval')}
            if(-not[int]::TryParse($w.Tag.RetentionBox.Text,[ref]$r)-or$r-lt1-or$r-gt3650){throw (Get-ServerPulseText 'agent.retention')}
            $w.Tag.Result=[PSCustomObject]@{IntervalSeconds=$i;RetentionDays=$r;AutoRestoreOnStartup=[bool]$w.Tag.Restore.IsChecked}
            $w.DialogResult=$true
        }catch{[Windows.MessageBox]::Show($w,$_.Exception.Message,(Get-ServerPulseText 'manager.inputError'),'OK','Error')|Out-Null}
    })
    $cancel.Tag=$dialog;$cancel.Add_Click({param($sender,$eventArgs);$sender.Tag.DialogResult=$false})
    Update-ServerPulseThemeVisualTree $dialog
    [void]$dialog.ShowDialog()
    return $dialog.Tag.Result
}

function Show-ServerPulseAgentMergeDialog {
    param([Windows.Window]$Owner)
    $dialog=[Windows.Window]::new();$dialog.Title=Get-ServerPulseText 'agent.mergeTitle';$dialog.Width=400;$dialog.Height=210;$dialog.Owner=$Owner
    $dialog.WindowStartupLocation='CenterOwner';$dialog.ShowInTaskbar=$false;$dialog.ResizeMode='NoResize'
    $dialog.Background=New-ServerManagerBrush '#101411';$dialog.Foreground=New-ServerManagerBrush '#E7ECE8';$dialog.FontFamily='Microsoft YaHei UI'
    $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=18;$dialog.Content=$panel
    $clean=[Windows.Controls.CheckBox]::new();$clean.Content=Get-ServerPulseText 'agent.mergeClean';$clean.IsChecked=$false;$clean.Foreground=New-ServerManagerBrush '#D9E0DB';Set-ServerManagerCheckBoxVisual $clean;[void]$panel.Children.Add($clean)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.Margin='0,24,0,0'
    $ok=[Windows.Controls.Button]::new();$ok.Content=Get-ServerPulseText 'agent.mergeRun';$ok.Padding='14,4';Set-ServerManagerButtonVisual $ok -Accent
    $cancel=[Windows.Controls.Button]::new();$cancel.Content=Get-ServerPulseText 'manager.cancel';$cancel.Padding='14,4';$cancel.Margin='8,0,0,0';Set-ServerManagerButtonVisual $cancel
    [void]$buttons.Children.Add($ok);[void]$buttons.Children.Add($cancel);[void]$panel.Children.Add($buttons)
    $dialog.Tag=[PSCustomObject]@{Clean=$clean;Result=$null}
    $ok.Tag=$dialog;$ok.Add_Click({param($sender,$eventArgs);$w=$sender.Tag;$w.Tag.Result=[PSCustomObject]@{CleanMerged=[bool]$w.Tag.Clean.IsChecked};$w.DialogResult=$true})
    $cancel.Tag=$dialog;$cancel.Add_Click({param($sender,$eventArgs);$sender.Tag.DialogResult=$false})
    Update-ServerPulseThemeVisualTree $dialog
    [void]$dialog.ShowDialog()
    return $dialog.Tag.Result
}

function Show-ServerPulseManualServerDialog {
    param([Windows.Window]$Owner,$Server=$null)
    $editing=$null-ne$Server
    $dialog=[Windows.Window]::new();$dialog.Title=if($editing){Get-ServerPulseText 'manager.editTitle'}else{Get-ServerPulseText 'manager.addTitle'};$dialog.Width=380;$dialog.Height=370;$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Background=New-ServerManagerBrush '#101411';$dialog.Foreground=New-ServerManagerBrush '#E7ECE8';$dialog.ResizeMode='NoResize'
    $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=18;$dialog.Content=$panel
    $initial=@{Label=if($editing){[string]$Server.Label}else{''};Host=if($editing){[string]$Server.HostName}else{''};Port=if($editing){[string]$Server.Port}else{'22'};User=if($editing){[string]$Server.User}else{''}}
    $inputs=@{};foreach($field in @(@('Label',(Get-ServerPulseText 'manager.displayName')),@('Host',(Get-ServerPulseText 'manager.host')),@('Port',(Get-ServerPulseText 'manager.port')),@('User',(Get-ServerPulseText 'manager.user')))){$label=[Windows.Controls.TextBlock]::new();$label.Text=$field[1];$label.Margin='0,4,0,3';[void]$panel.Children.Add($label);$box=[Windows.Controls.TextBox]::new();$box.Height=28;$box.Padding='6,3';$box.Text=$initial[$field[0]];[void]$panel.Children.Add($box);$inputs[$field[0]]=$box}
    $inherit=[Windows.Controls.CheckBox]::new();$inherit.Content=Get-ServerPulseText 'manager.inherit';$inherit.IsChecked=$true;$inherit.Visibility=if($editing){'Visible'}else{'Collapsed'};$inherit.Margin='0,9,0,0';$inherit.ToolTip=Get-ServerPulseText 'manager.inheritTip';Set-ServerManagerCheckBoxVisual $inherit;[void]$panel.Children.Add($inherit)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.Margin='0,14,0,0';$ok=[Windows.Controls.Button]::new();$ok.Content=if($editing){Get-ServerPulseText 'manager.save'}else{Get-ServerPulseText 'manager.add'};$ok.Padding='14,4';Set-ServerManagerButtonVisual $ok -Accent;$cancel=[Windows.Controls.Button]::new();$cancel.Content=Get-ServerPulseText 'manager.cancel';$cancel.Padding='14,4';$cancel.Margin='8,0,0,0';Set-ServerManagerButtonVisual $cancel;[void]$buttons.Children.Add($ok);[void]$buttons.Children.Add($cancel);[void]$panel.Children.Add($buttons)
    $dialog.Tag=[PSCustomObject]@{Inputs=$inputs;Original=$Server;Inherit=$inherit;Result=$null};$ok.Tag=$dialog;$ok.Add_Click({param($sender,$eventArgs);$w=$sender.Tag;try{$i=$w.Tag.Inputs;$port=0;if(-not[int]::TryParse($i.Port.Text,[ref]$port)){throw (Get-ServerPulseText 'manager.invalidPort')};$original=$w.Tag.Original;$server=New-ServerPulseManagedServer -Id $(if($null-ne$original){[string]$original.Id}else{$null}) -Label $i.Label.Text.Trim() -Source manual -SshTarget $i.Host.Text.Trim() -HostName $i.Host.Text.Trim() -Port $port -User $i.User.Text.Trim() -Monitored $(if($null-ne$original){[bool]$original.Monitored}else{$true});if(-not$server.Label){throw (Get-ServerPulseText 'manager.emptyLabel')};$w.Tag.Result=[PSCustomObject]@{Server=$server;InheritHistory=[bool]$w.Tag.Inherit.IsChecked};$w.DialogResult=$true}catch{[Windows.MessageBox]::Show($w,$_.Exception.Message,(Get-ServerPulseText 'manager.inputError'),'OK','Error')|Out-Null}});$cancel.Tag=$dialog;$cancel.Add_Click({param($sender,$eventArgs);$sender.Tag.DialogResult=$false})
    Update-ServerPulseThemeVisualTree $dialog
    [void]$dialog.ShowDialog();return $dialog.Tag.Result
}

function Show-ServerPulseServerManager {
    param([Windows.Window]$Owner,$Store,[hashtable]$SessionSecrets,[string]$AskPassPath,[int]$TimeoutMs,[hashtable]$ValidationStates,[scriptblock]$OnRetryRequested,[scriptblock]$OnApplied,[switch]$SmokeTest,[string]$AgentStatePath='',[string]$HistoryDirectory='',[string]$AgentModulePath='',[string]$SampleModulePath='')
    if([string]::IsNullOrWhiteSpace($AgentModulePath)){$AgentModulePath=Join-Path $PSScriptRoot 'ServerPulse.Agent.ps1'}
    if([string]::IsNullOrWhiteSpace($SampleModulePath)){$SampleModulePath=Join-Path $PSScriptRoot 'ServerPulse.Sample.ps1'}
    $StorageModulePath=Join-Path $PSScriptRoot 'ServerPulse.Storage.ps1'
    $CoreModulePath=Join-Path $PSScriptRoot 'ServerPulse.Core.ps1'
    $window=[Windows.Window]::new();$window.Title=Get-ServerPulseText 'manager.title';$window.Width=640;$window.Height=650;$window.MinWidth=520;$window.MinHeight=420;$window.Owner=$Owner;$window.WindowStartupLocation='CenterOwner';$window.ShowInTaskbar=$false;$window.Background=New-ServerManagerBrush '#0D100E';$window.Foreground=New-ServerManagerBrush '#E7ECE8';$window.FontFamily='Microsoft YaHei UI'
    $topmostBinding=[Windows.Data.Binding]::new('Topmost');$topmostBinding.Source=$Owner;$topmostBinding.Mode='OneWay';[void]$window.SetBinding([Windows.Window]::TopmostProperty,$topmostBinding)
    $root=[Windows.Controls.DockPanel]::new();$root.Margin=16;$window.Content=$root
    $footer=[Windows.Controls.StackPanel]::new();$footer.Orientation='Horizontal';$footer.HorizontalAlignment='Right';$footer.Margin='0,12,0,0';[Windows.Controls.DockPanel]::SetDock($footer,'Bottom');[void]$root.Children.Add($footer)
    $add=[Windows.Controls.Button]::new();$add.Content=Get-ServerPulseText 'manager.add';$add.Padding='12,5';Set-ServerManagerButtonVisual $add
    $apply=[Windows.Controls.Button]::new();$apply.Content=Get-ServerPulseText 'manager.apply';$apply.Padding='14,5';$apply.Margin='8,0,0,0';Set-ServerManagerButtonVisual $apply -Accent
    $cancel=[Windows.Controls.Button]::new();$cancel.Content=Get-ServerPulseText 'manager.cancel';$cancel.Padding='14,5';$cancel.Margin='8,0,0,0';Set-ServerManagerButtonVisual $cancel
    foreach($b in @($add,$apply,$cancel)){[void]$footer.Children.Add($b)}
    $introPanel=[Windows.Controls.StackPanel]::new();$introPanel.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($introPanel,'Top');[void]$root.Children.Add($introPanel)
    $intro=[Windows.Controls.TextBlock]::new();$intro.Text=Get-ServerPulseText 'manager.intro';$intro.TextWrapping='Wrap';$intro.Foreground=New-ServerManagerBrush '#9DA7A0';[void]$introPanel.Children.Add($intro)
    $agentHint=[Windows.Controls.TextBlock]::new();$agentHint.Text=Get-ServerPulseText 'agent.hint';$agentHint.TextWrapping='Wrap';$agentHint.Foreground=New-ServerManagerBrush '#657069';$agentHint.FontSize=9;$agentHint.Margin='0,6,0,0';[void]$introPanel.Children.Add($agentHint)
    $discoveryStatus=[Windows.Controls.TextBlock]::new();$discoveryStatus.Text=Get-ServerPulseText 'manager.waitingDiscovery';$discoveryStatus.Foreground=New-ServerManagerBrush '#657069';$discoveryStatus.FontSize=9;$discoveryStatus.Margin='0,5,0,0';[void]$introPanel.Children.Add($discoveryStatus)
    $mergeAll=[Windows.Controls.Button]::new();$mergeAll.Content=Get-ServerPulseText 'agent.mergeAll';$mergeAll.Padding='10,3';$mergeAll.Margin='0,8,0,0';$mergeAll.HorizontalAlignment='Left';Set-ServerManagerButtonVisual $mergeAll;[void]$introPanel.Children.Add($mergeAll)
    $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$panel=[Windows.Controls.StackPanel]::new();$scroll.Content=$panel;[void]$root.Children.Add($scroll)
    $workingSecrets=New-ServerPulseSessionSecretStore
    foreach($identity in @($SessionSecrets.Keys)){$secret=Get-ServerPulseSessionSecret $SessionSecrets $identity;if($null-ne$secret){Set-ServerPulseSessionSecret $workingSecrets $identity $secret};$secret=$null}
    if($null-eq$ValidationStates){$ValidationStates=@{}}
    $context=[PSCustomObject]@{Window=$window;Panel=$panel;Intro=$intro;AddButton=$add;ApplyButton=$apply;CancelButton=$cancel;Rows=[Collections.ArrayList]::new();PendingCredentialWrites=@{};PendingCredentialDeletes=[Collections.ArrayList]::new();Store=$Store;SessionSecrets=$workingSecrets;OriginalSessionSecrets=$SessionSecrets;ValidationStates=$ValidationStates;AskPassPath=$AskPassPath;TimeoutMs=$TimeoutMs;ModulePath=(Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1');SshModulePath=(Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1');DiscoveryStatus=$discoveryStatus;DiscoveryState='waiting';DiscoveryCount=0;DiscoveryTimer=$null;DiscoveryPowerShell=$null;DiscoveryAsync=$null;KnownTargets=$null;OnRetryRequested=$OnRetryRequested;OnApplied=$OnApplied;AgentStatePath=$AgentStatePath;HistoryDirectory=$HistoryDirectory;AgentModulePath=$AgentModulePath;SampleModulePath=$SampleModulePath;StorageModulePath=$StorageModulePath;CoreModulePath=$CoreModulePath;AgentState=$(if(-not[string]::IsNullOrWhiteSpace($AgentStatePath)){Read-ServerPulseAgentState $AgentStatePath}else{New-ServerPulseAgentState});AgentOps=[Collections.ArrayList]::new();AgentOpTimer=$null;MergeAllButton=$mergeAll}
    foreach($server in @($Store.Servers)){ $copy=Copy-ServerPulseManagedServer $server;$row=New-ServerManagerRow $context $copy;[void]$context.Rows.Add($row);[void]$panel.Children.Add($row.Surface) }
    Start-ServerManagerCandidateDiscovery $context
    # Probe every row once the window is shown: rows with a local entry
    # refresh their badge, and rows without one adopt an agent that is
    # already running on the server (see Complete-ServerManagerAgentOperation).
    # Deferred so construction and smoke tests never depend on SSH state.
    if(-not$SmokeTest){
        $window.Add_Loaded({param($sender,$eventArgs);$ctx=$sender.Tag;foreach($row in @($ctx.Rows)){try{Invoke-ServerManagerAgentOperation $ctx $row status}catch{}}})
    }
    $mergeAll.Tag=$context;$mergeAll.Add_Click({param($sender,$eventArgs);$ctx=$sender.Tag;foreach($row in @($ctx.Rows)){if($null-ne(Get-ServerPulseAgentServerEntry $ctx.AgentState ([string]$row.Server.Id))){Invoke-ServerManagerAgentOperation $ctx $row merge}}})
    $add.Tag=$context;$add.Add_Click({param($sender,$eventArgs);$ctx=$sender.Tag;$result=Show-ServerPulseManualServerDialog $ctx.Window;if($null-ne$result){$row=New-ServerManagerRow $ctx $result.Server;[void]$ctx.Rows.Add($row);[void]$ctx.Panel.Children.Add($row.Surface);Invoke-ServerManagerRowTest $row}})
    $cancel.Tag=$window;$cancel.Add_Click({param($sender,$eventArgs);$sender.Tag.Close()})
    $apply.Tag=$context;$apply.Add_Click({
        param($sender,$eventArgs);$ctx=$sender.Tag;$sender.IsEnabled=$false
        try{
            $requests=@();$requestRows=@{}
            foreach($row in @($ctx.Rows)){if(-not$row.Server.Monitored){continue};if($row.Status -notin @('online','passwordless')){$password=Get-ServerPulseAuthenticationPassword $row $ctx.SessionSecrets;$requests+=[PSCustomObject]@{Id=$row.Server.Id;Server=$row.Server;Password=$password};$requestRows[[string]$row.Server.Id]=[PSCustomObject]@{Row=$row;Password=$password}}}
            if($requests.Count -gt 0){$results=Invoke-ServerPulseAuthenticationBatch $requests $ctx.ModulePath $ctx.AskPassPath $ctx.TimeoutMs;foreach($result in $results){$request=$requestRows[[string]$result.Id];Complete-ServerPulseAuthenticationResult $ctx $request.Row $result $request.Password}}
            $newMonitoredIdentities=@($ctx.Rows|Where-Object{$_.Server.Monitored}|ForEach-Object{$_.Server.Identity})
            foreach($identity in @($ctx.PendingCredentialWrites.Keys)){$pending=$ctx.PendingCredentialWrites[$identity];Set-ServerPulseStoredCredential -Identity $identity -UserName $pending.UserName -Password $pending.Password}
            foreach($identity in @($ctx.PendingCredentialDeletes|Select-Object -Unique)){if(-not$ctx.PendingCredentialWrites.ContainsKey($identity)){[void](Remove-ServerPulseStoredCredential $identity)}}
            $ctx.Store.Servers=@($ctx.Rows|Where-Object{$_.Server.Source-ne'sshConfig'-or$_.Server.Monitored}|ForEach-Object{$_.Server})
            Save-ServerPulseServerStore $ctx.Store
            Clear-ServerPulseSessionSecrets $ctx.OriginalSessionSecrets
            foreach($identity in @($ctx.SessionSecrets.Keys)){if($identity-in$newMonitoredIdentities-and-not$ctx.PendingCredentialWrites.ContainsKey($identity)){$secret=Get-ServerPulseSessionSecret $ctx.SessionSecrets $identity;if($null-ne$secret){Set-ServerPulseSessionSecret $ctx.OriginalSessionSecrets $identity $secret};$secret=$null}}
            if($null-ne$ctx.OnApplied){& $ctx.OnApplied $ctx.Store @($ctx.Rows)}
            $ctx.Window.Close()
        }catch{[Windows.MessageBox]::Show($ctx.Window,$_.Exception.Message,(Get-ServerPulseText 'manager.applyError'),'OK','Error')|Out-Null}
        finally{$sender.IsEnabled=$true}
    })
    $window.Tag=$context;$window.Add_Closed({param($sender,$eventArgs);$ctx=$sender.Tag;Stop-ServerManagerCandidateDiscovery $ctx;Stop-ServerManagerAgentOperations $ctx;Clear-ServerPulseSessionSecrets $ctx.SessionSecrets;foreach($pending in @($ctx.PendingCredentialWrites.Values)){$pending.Password=$null};$ctx.PendingCredentialWrites.Clear()})
    Update-ServerPulseThemeVisualTree $window
    $result=[PSCustomObject]@{Window=$window;Context=$context;ApplyButton=$apply;AddButton=$add}
    if(-not$SmokeTest){$window.Show();[void]$window.Activate()}
    return $result
}
