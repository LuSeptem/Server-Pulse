function New-ServerManagerBrush([string]$Color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($Color) }

function Copy-ServerPulseManagedServer {
    param($Server)
    return New-ServerPulseManagedServer -Id ([string]$Server.Id) -Label ([string]$Server.Label) -Source ([string]$Server.Source) -SshTarget ([string]$Server.SshTarget) -HostName ([string]$Server.HostName) -Port ([int]$Server.Port) -User ([string]$Server.User) -Monitored ([bool]$Server.Monitored)
}

function Get-ServerPulseCredentialState {
    param($Server, [hashtable]$SessionSecrets)
    if ($null -ne (Get-ServerPulseSessionSecret $SessionSecrets $Server.Identity)) { return '仅本次' }
    if (Test-ServerPulseStoredCredential $Server.Identity) { return '已保存' }
    return '无凭据'
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
        'online'{'已验证'} 'passwordless'{'免密已验证'} 'authentication_required'{'需要密码'} 'authentication_failed'{'认证已暂停'}
        'host_key_unknown'{'等待确认指纹'} 'host_key_changed'{'主机指纹已变化'} 'connection'{'连接暂不可用'} default{'尚未验证'}
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
        $text="首次连接无法验证服务器身份。请通过可信渠道核对以下 SHA256 指纹：`n`n"+($probe.Fingerprints -join "`n")+"`n`n确认信任并写入当前用户 known_hosts？"
        $answer=[Windows.MessageBox]::Show($Owner,$text,'确认 SSH 主机指纹','YesNo','Warning')
        if($answer -ne 'Yes'){return $false}
        [void](Add-ServerPulseTrustedHostKey -Lines $probe.Lines)
        return $true
    } catch { [Windows.MessageBox]::Show($Owner,$_.Exception.Message,'主机指纹错误','OK','Error')|Out-Null;return $false }
}

function Complete-ServerPulseAuthenticationResult {
    param($Context,$RowState,$Result,[string]$Password)
    if($Result.Status -eq 'host_key_unknown'){
        if(Confirm-ServerPulseHostKey -Owner $Context.Window -RowState $RowState -TimeoutMs $Context.TimeoutMs){
            $retry=Invoke-ServerPulseAuthenticationBatch -Requests @([PSCustomObject]@{Id=$RowState.Server.Id;Server=$RowState.Server;Password=$Password}) -ModulePath $Context.ModulePath -AskPassPath $Context.AskPassPath -TimeoutMs $Context.TimeoutMs
            if($retry.Count -gt 0){$Result=$retry[0]}
        }
    }
    if($Result.Status -eq 'host_key_changed'){
        $lookup=if([int]$RowState.Server.Port-eq22){[string]$RowState.Server.HostName}else{"[$($RowState.Server.HostName)]:$([int]$RowState.Server.Port)"}
        $command="ssh-keygen -R `"$lookup`""
        $old=@(Get-ServerPulseKnownHostFingerprints $RowState.Server)
        try{$new=@((Get-ServerPulseHostKeyProbe -Server $RowState.Server -TimeoutMs $Context.TimeoutMs).Fingerprints)}catch{$new=@("无法安全读取新指纹：$($_.Exception.Message)")}
        $message="SSH 主机指纹与 known_hosts 不一致，连接已阻断。请先从可信渠道核验，软件不会自动替换。`n`n旧指纹：`n$($old-join"`n")`n`n新指纹：`n$($new-join"`n")`n`n人工确认后参考命令：$command"
        [Windows.MessageBox]::Show($Context.Window,$message,'SSH 主机身份变化','OK','Error')|Out-Null
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
        $RowState.CredentialText.Text=if($Context.PendingCredentialWrites.ContainsKey($RowState.Server.Identity)){'已保存（待应用）'}else{Get-ServerPulseCredentialState $RowState.Server $Context.SessionSecrets}
        $RowState.DeleteCredentialButton.Visibility=if($RowState.CredentialText.Text-eq'已保存'){'Visible'}else{'Collapsed'}
    }else{Set-ServerManagerRowStatus $RowState ([string]$Result.Status) ([string]$Result.Error)}
}

function Invoke-ServerManagerRowTest {
    param($RowState)
    $context=$RowState.Context
    $password=Get-ServerPulseAuthenticationPassword $RowState $context.SessionSecrets
    $RowState.TestButton.IsEnabled=$false;Set-ServerManagerRowStatus $RowState testing
    try{
        $results=Invoke-ServerPulseAuthenticationBatch -Requests @([PSCustomObject]@{Id=$RowState.Server.Id;Server=$RowState.Server;Password=$password}) -ModulePath $context.ModulePath -AskPassPath $context.AskPassPath -TimeoutMs $context.TimeoutMs
        if($results.Count -eq 0){throw 'SSH 验证未返回结果'}
        Complete-ServerPulseAuthenticationResult $context $RowState $results[0] $password
    }catch{Set-ServerManagerRowStatus $RowState connection $_.Exception.Message}
    finally{$RowState.TestButton.IsEnabled=$true}
}

function Register-ServerManagerRowEvents {
    param($State)
    $State.TestButton.Tag=$State;$State.TestButton.Add_Click({param($sender,$eventArgs);Invoke-ServerManagerRowTest $sender.Tag})
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
        $answer=[Windows.MessageBox]::Show($s.Context.Window,"删除登录身份 $($s.Server.Identity) 的 Windows 凭据？`n`n受影响服务器：$affected",'删除凭据','YesNo','Warning')
        if($answer-eq'Yes'){
            [void]$s.Context.PendingCredentialWrites.Remove($s.Server.Identity);[void]$s.Context.PendingCredentialDeletes.Add($s.Server.Identity)
            $s.CredentialText.Text=if($null-ne(Get-ServerPulseSessionSecret $s.Context.SessionSecrets $s.Server.Identity)){'仅本次'}else{'无凭据（待应用）'}
            $s.DeleteCredentialButton.Visibility='Collapsed'
        }
    })
    $State.EditButton.Tag=$State;$State.EditButton.Add_Click({
        param($sender,$eventArgs);$s=$sender.Tag;$edited=Show-ServerPulseManualServerDialog -Owner $s.Context.Window -Server $s.Server
        if($null-eq$edited){return};$oldIdentity=$s.Server.Identity;$identityChanged=$edited.Server.Identity-ne$oldIdentity
        if($identityChanged){
            if(((Test-ServerPulseStoredCredential $oldIdentity)-or$s.Context.PendingCredentialWrites.ContainsKey($oldIdentity))-and[Windows.MessageBox]::Show($s.Context.Window,'连接身份已改变，旧密码不会迁移。应用修改时是否删除旧 Windows 凭据？','旧凭据','YesNo','Question')-eq'Yes'){[void]$s.Context.PendingCredentialWrites.Remove($oldIdentity);[void]$s.Context.PendingCredentialDeletes.Add($oldIdentity)}
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
        $answer=[Windows.MessageBox]::Show($s.Context.Window,"从 Server Pulse 删除「$($s.Server.Label)」？旧历史不会删除。",'删除服务器','YesNo','Warning')
        if($answer -ne 'Yes'){return}
        $affected=@($s.Context.Rows|Where-Object{$_.Server.Identity-eq$s.Server.Identity}|ForEach-Object{$_.Server.Label})-join'、'
        if(((Test-ServerPulseStoredCredential $s.Server.Identity)-or$s.Context.PendingCredentialWrites.ContainsKey($s.Server.Identity)) -and [Windows.MessageBox]::Show($s.Context.Window,"应用删除时，同时从 Windows 凭据管理器删除此登录身份的密码？`n`n受影响服务器：$affected",'删除凭据','YesNo','Question') -eq 'Yes'){[void]$s.Context.PendingCredentialWrites.Remove($s.Server.Identity);[void]$s.Context.PendingCredentialDeletes.Add($s.Server.Identity)}
        $s.Context.Rows.Remove($s);[void]$s.Context.Panel.Children.Remove($s.Surface)
    })
}

function New-ServerManagerRow {
    param($Context,$Server)
    $surface=[Windows.Controls.Border]::new();$surface.Background=New-ServerManagerBrush '#151A17';$surface.BorderBrush=New-ServerManagerBrush '#303731';$surface.BorderThickness=1;$surface.CornerRadius=7;$surface.Padding=10;$surface.Margin='0,0,0,8'
    $stack=[Windows.Controls.StackPanel]::new();$surface.Child=$stack
    $header=[Windows.Controls.Grid]::new();[void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$auto=[Windows.Controls.ColumnDefinition]::new();$auto.Width='Auto';[void]$header.ColumnDefinitions.Add($auto)
    $monitor=[Windows.Controls.CheckBox]::new();$monitor.Content=$Server.Label;$monitor.IsChecked=[bool]$Server.Monitored;$monitor.Foreground=New-ServerManagerBrush '#EDF2EE';$monitor.FontSize=13;$monitor.FontWeight='SemiBold'
    $status=[Windows.Controls.TextBlock]::new();$status.Text='尚未验证';$status.Foreground=New-ServerManagerBrush '#7A857E';$status.FontSize=9;$status.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($status,1)
    [void]$header.Children.Add($monitor);[void]$header.Children.Add($status);[void]$stack.Children.Add($header)
    $meta=[Windows.Controls.TextBlock]::new();$meta.Text=("{0}  ·  {1}@{2}:{3}" -f $Server.SshTarget,$Server.User,$Server.HostName,$Server.Port);$meta.Foreground=New-ServerManagerBrush '#78827C';$meta.FontSize=9;$meta.Margin='22,4,0,6';[void]$stack.Children.Add($meta)
    $tools=[Windows.Controls.StackPanel]::new();$tools.Orientation='Horizontal';$tools.Margin='22,0,0,4'
    $passwordless=[Windows.Controls.CheckBox]::new();$passwordless.Content='免密登录';$passwordless.IsHitTestVisible=$false;$passwordless.Focusable=$false;$passwordless.Foreground=New-ServerManagerBrush '#AAB3AD';$passwordless.FontSize=9;$passwordless.Margin='0,0,4,0'
    $info=[Windows.Controls.Border]::new();$info.Width=16;$info.Height=16;$info.CornerRadius=8;$info.Background=New-ServerManagerBrush '#29312B';$info.Margin='0,0,12,0';$info.Cursor='Help';$mark=[Windows.Controls.TextBlock]::new();$mark.Text='!';$mark.Foreground=New-ServerManagerBrush '#E4B64B';$mark.HorizontalAlignment='Center';$mark.VerticalAlignment='Center';$mark.FontWeight='Bold';$info.Child=$mark
    $info.ToolTip='“免密登录”由实际 BatchMode SSH 自动检测，通常来自密钥、ssh-agent 或 SSH 配置。Windows 凭据只供 Server Pulse 使用，终端 ssh 不会自动读取。'
    $credential=[Windows.Controls.TextBlock]::new();$credential.Text=Get-ServerPulseCredentialState $Server $Context.SessionSecrets;$credential.Foreground=New-ServerManagerBrush '#87928B';$credential.FontSize=9;$credential.VerticalAlignment='Center'
    $updateCredential=[Windows.Controls.Button]::new();$updateCredential.Content='更新密码';$updateCredential.Margin='7,0,0,0';$updateCredential.Padding='7,2'
    $deleteCredential=[Windows.Controls.Button]::new();$deleteCredential.Content='删除凭据';$deleteCredential.Margin='5,0,0,0';$deleteCredential.Padding='7,2';$deleteCredential.Visibility=if($credential.Text-eq'已保存'){'Visible'}else{'Collapsed'}
    $test=[Windows.Controls.Button]::new();$test.Content='重新检测';$test.Margin='12,0,0,0';$test.Padding='8,2';$test.Foreground=New-ServerManagerBrush '#D9E0DB';$test.Background=New-ServerManagerBrush '#252C27';$test.BorderBrush=New-ServerManagerBrush '#3A443D'
    $edit=[Windows.Controls.Button]::new();$edit.Content='编辑';$edit.Margin='6,0,0,0';$edit.Padding='8,2';$edit.Visibility=if($Server.Source -eq 'sshConfig'){'Collapsed'}else{'Visible'}
    $delete=[Windows.Controls.Button]::new();$delete.Content='删除';$delete.Margin='6,0,0,0';$delete.Padding='8,2';$delete.Visibility=if($Server.Source -eq 'sshConfig'){'Collapsed'}else{'Visible'}
    foreach($control in @($passwordless,$info,$credential,$updateCredential,$deleteCredential,$test,$edit,$delete)){[void]$tools.Children.Add($control)};[void]$stack.Children.Add($tools)
    $passwordPanel=[Windows.Controls.StackPanel]::new();$passwordPanel.Margin='22,5,0,2';$passwordPanel.Visibility='Collapsed'
    $passwordLine=[Windows.Controls.Grid]::new();[void]$passwordLine.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$eyeColumn=[Windows.Controls.ColumnDefinition]::new();$eyeColumn.Width='Auto';[void]$passwordLine.ColumnDefinitions.Add($eyeColumn)
    $password=[Windows.Controls.PasswordBox]::new();$password.Height=26;$password.Padding='6,3';$password.Background=New-ServerManagerBrush '#202622';$password.Foreground=New-ServerManagerBrush '#E7ECE8';$password.BorderBrush=New-ServerManagerBrush '#3A443D'
    $reveal=[Windows.Controls.TextBox]::new();$reveal.Height=26;$reveal.Padding='6,3';$reveal.IsReadOnly=$true;$reveal.Visibility='Collapsed';$reveal.Background=$password.Background;$reveal.Foreground=$password.Foreground
    $eye=[Windows.Controls.Button]::new();$eye.Content='按住显示';$eye.Margin='6,0,0,0';$eye.Padding='7,2';[Windows.Controls.Grid]::SetColumn($eye,1)
    [void]$passwordLine.Children.Add($password);[void]$passwordLine.Children.Add($reveal);[void]$passwordLine.Children.Add($eye);[void]$passwordPanel.Children.Add($passwordLine)
    $save=[Windows.Controls.CheckBox]::new();$save.Content='存入 Windows 凭据管理器';$save.IsChecked=$false;$save.Foreground=New-ServerManagerBrush '#AAB3AD';$save.FontSize=9;$save.Margin='0,6,0,0';[void]$passwordPanel.Children.Add($save);[void]$stack.Children.Add($passwordPanel)
    $state=[PSCustomObject]@{Context=$Context;Server=$Server;Surface=$surface;Monitor=$monitor;Meta=$meta;StatusText=$status;Passwordless=$passwordless;CredentialText=$credential;UpdateCredentialButton=$updateCredential;DeleteCredentialButton=$deleteCredential;TestButton=$test;EditButton=$edit;DeleteButton=$delete;PasswordPanel=$passwordPanel;PasswordBox=$password;Reveal=$reveal;Eye=$eye;SaveCredential=$save;Status='unknown';AuthMode='auto'}
    Register-ServerManagerRowEvents $state
    return $state
}

function Start-ServerManagerCandidateDiscovery {
    param($Context)
    $known=@{};foreach($row in @($Context.Rows)){$known[[string]$row.Server.SshTarget]=$true}
    $context.KnownTargets=$known
    $context.DiscoveryStatus.Text='正在后台发现 SSH 配置…'
    $context.DiscoveryPowerShell=[PowerShell]::Create()
    $context.DiscoveryPowerShell.AddScript({param($ModulePath);$ErrorActionPreference='Stop';. $ModulePath;$results=foreach($alias in @(Get-ServerPulseSshConfigAliases)){try{$resolved=Get-ServerPulseSshResolvedTarget $alias;[PSCustomObject]@{Alias=$alias;HostName=$resolved.HostName;Port=$resolved.Port;User=$resolved.User}}catch{}};return @($results)}).AddArgument($Context.SshModulePath)|Out-Null
    $context.DiscoveryAsync=$context.DiscoveryPowerShell.BeginInvoke()
    $context.DiscoveryTimer=[Windows.Threading.DispatcherTimer]::new();$context.DiscoveryTimer.Interval=[TimeSpan]::FromMilliseconds(100);$context.DiscoveryTimer.Tag=$context
    $context.DiscoveryTimer.Add_Tick({param($sender,$eventArgs);$ctx=$sender.Tag;if(-not$ctx.DiscoveryAsync.IsCompleted){return};$sender.Stop();try{$found=@($ctx.DiscoveryPowerShell.EndInvoke($ctx.DiscoveryAsync));foreach($resolved in $found){if($ctx.KnownTargets.ContainsKey([string]$resolved.Alias)){continue};$server=New-ServerPulseManagedServer -Label ([string]$resolved.Alias) -Source sshConfig -SshTarget ([string]$resolved.Alias) -HostName ([string]$resolved.HostName) -Port ([int]$resolved.Port) -User ([string]$resolved.User) -Monitored $false;$row=New-ServerManagerRow $ctx $server;[void]$ctx.Rows.Add($row);[void]$ctx.Panel.Children.Add($row.Surface);$ctx.KnownTargets[[string]$resolved.Alias]=$true};$ctx.DiscoveryStatus.Text=if($found.Count){"已发现 $($found.Count) 个 SSH 配置项"}else{'未发现新的 SSH 配置项'}}catch{$ctx.DiscoveryStatus.Text='SSH 配置发现失败，可继续手动添加'}finally{$ctx.DiscoveryPowerShell.Dispose();$ctx.DiscoveryPowerShell=$null;$ctx.DiscoveryAsync=$null}})
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

function Show-ServerPulseManualServerDialog {
    param([Windows.Window]$Owner,$Server=$null)
    $editing=$null-ne$Server
    $dialog=[Windows.Window]::new();$dialog.Title=if($editing){'编辑 SSH 服务器'}else{'添加 SSH 服务器'};$dialog.Width=380;$dialog.Height=370;$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Background=New-ServerManagerBrush '#101411';$dialog.Foreground=New-ServerManagerBrush '#E7ECE8';$dialog.ResizeMode='NoResize'
    $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=18;$dialog.Content=$panel
    $initial=@{Label=if($editing){[string]$Server.Label}else{''};Host=if($editing){[string]$Server.HostName}else{''};Port=if($editing){[string]$Server.Port}else{'22'};User=if($editing){[string]$Server.User}else{''}}
    $inputs=@{};foreach($field in @(@('Label','显示名称'),@('Host','主机或 IP'),@('Port','端口'),@('User','用户名'))){$label=[Windows.Controls.TextBlock]::new();$label.Text=$field[1];$label.Margin='0,4,0,3';[void]$panel.Children.Add($label);$box=[Windows.Controls.TextBox]::new();$box.Height=28;$box.Padding='6,3';$box.Text=$initial[$field[0]];[void]$panel.Children.Add($box);$inputs[$field[0]]=$box}
    $inherit=[Windows.Controls.CheckBox]::new();$inherit.Content='继承原服务器历史';$inherit.IsChecked=$true;$inherit.Visibility=if($editing){'Visible'}else{'Collapsed'};$inherit.Margin='0,9,0,0';$inherit.ToolTip='取消后会生成新的服务器 ID；旧历史仍保留到期。若连接到不同物理服务器，建议取消。';[void]$panel.Children.Add($inherit)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.Margin='0,14,0,0';$ok=[Windows.Controls.Button]::new();$ok.Content=if($editing){'保存'}else{'添加'};$ok.Padding='14,4';$cancel=[Windows.Controls.Button]::new();$cancel.Content='取消';$cancel.Padding='14,4';$cancel.Margin='8,0,0,0';[void]$buttons.Children.Add($ok);[void]$buttons.Children.Add($cancel);[void]$panel.Children.Add($buttons)
    $dialog.Tag=[PSCustomObject]@{Inputs=$inputs;Original=$Server;Inherit=$inherit;Result=$null};$ok.Tag=$dialog;$ok.Add_Click({param($sender,$eventArgs);$w=$sender.Tag;try{$i=$w.Tag.Inputs;$port=0;if(-not[int]::TryParse($i.Port.Text,[ref]$port)){throw '端口必须是数字'};$original=$w.Tag.Original;$server=New-ServerPulseManagedServer -Id $(if($null-ne$original){[string]$original.Id}else{$null}) -Label $i.Label.Text.Trim() -Source manual -SshTarget $i.Host.Text.Trim() -HostName $i.Host.Text.Trim() -Port $port -User $i.User.Text.Trim() -Monitored $(if($null-ne$original){[bool]$original.Monitored}else{$true});if(-not$server.Label){throw '显示名称不能为空'};$w.Tag.Result=[PSCustomObject]@{Server=$server;InheritHistory=[bool]$w.Tag.Inherit.IsChecked};$w.DialogResult=$true}catch{[Windows.MessageBox]::Show($w,$_.Exception.Message,'输入错误','OK','Error')|Out-Null}});$cancel.Tag=$dialog;$cancel.Add_Click({param($sender,$eventArgs);$sender.Tag.DialogResult=$false})
    [void]$dialog.ShowDialog();return $dialog.Tag.Result
}

function Show-ServerPulseServerManager {
    param([Windows.Window]$Owner,$Store,[hashtable]$SessionSecrets,[string]$AskPassPath,[int]$TimeoutMs,[scriptblock]$OnApplied,[switch]$SmokeTest)
    $window=[Windows.Window]::new();$window.Title='Server Pulse · SSH 服务器';$window.Width=620;$window.Height=650;$window.MinWidth=520;$window.MinHeight=420;$window.Owner=$Owner;$window.WindowStartupLocation='CenterOwner';$window.Background=New-ServerManagerBrush '#0D100E';$window.Foreground=New-ServerManagerBrush '#E7ECE8';$window.FontFamily='Microsoft YaHei UI'
    $root=[Windows.Controls.DockPanel]::new();$root.Margin=16;$window.Content=$root
    $footer=[Windows.Controls.StackPanel]::new();$footer.Orientation='Horizontal';$footer.HorizontalAlignment='Right';$footer.Margin='0,12,0,0';[Windows.Controls.DockPanel]::SetDock($footer,'Bottom');[void]$root.Children.Add($footer)
    $add=[Windows.Controls.Button]::new();$add.Content='添加服务器';$add.Padding='12,5';$apply=[Windows.Controls.Button]::new();$apply.Content='验证并应用';$apply.Padding='14,5';$apply.Margin='8,0,0,0';$cancel=[Windows.Controls.Button]::new();$cancel.Content='取消';$cancel.Padding='14,5';$cancel.Margin='8,0,0,0';foreach($b in @($add,$apply,$cancel)){[void]$footer.Children.Add($b)}
    $introPanel=[Windows.Controls.StackPanel]::new();$introPanel.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($introPanel,'Top');[void]$root.Children.Add($introPanel)
    $intro=[Windows.Controls.TextBlock]::new();$intro.Text='选择需要监视的 SSH 服务器。已验证服务器立即运行；缺少认证的服务器保持暂停，不影响其他服务器。';$intro.TextWrapping='Wrap';$intro.Foreground=New-ServerManagerBrush '#9DA7A0';[void]$introPanel.Children.Add($intro)
    $discoveryStatus=[Windows.Controls.TextBlock]::new();$discoveryStatus.Text='等待发现 SSH 配置';$discoveryStatus.Foreground=New-ServerManagerBrush '#657069';$discoveryStatus.FontSize=9;$discoveryStatus.Margin='0,5,0,0';[void]$introPanel.Children.Add($discoveryStatus)
    $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$panel=[Windows.Controls.StackPanel]::new();$scroll.Content=$panel;[void]$root.Children.Add($scroll)
    $workingSecrets=New-ServerPulseSessionSecretStore
    foreach($identity in @($SessionSecrets.Keys)){$secret=Get-ServerPulseSessionSecret $SessionSecrets $identity;if($null-ne$secret){Set-ServerPulseSessionSecret $workingSecrets $identity $secret};$secret=$null}
    $context=[PSCustomObject]@{Window=$window;Panel=$panel;Rows=[Collections.ArrayList]::new();PendingCredentialWrites=@{};PendingCredentialDeletes=[Collections.ArrayList]::new();Store=$Store;SessionSecrets=$workingSecrets;OriginalSessionSecrets=$SessionSecrets;AskPassPath=$AskPassPath;TimeoutMs=$TimeoutMs;ModulePath=(Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1');SshModulePath=(Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1');DiscoveryStatus=$discoveryStatus;DiscoveryTimer=$null;DiscoveryPowerShell=$null;DiscoveryAsync=$null;KnownTargets=$null;OnApplied=$OnApplied}
    foreach($server in @($Store.Servers)){ $copy=Copy-ServerPulseManagedServer $server;$row=New-ServerManagerRow $context $copy;[void]$context.Rows.Add($row);[void]$panel.Children.Add($row.Surface) }
    Start-ServerManagerCandidateDiscovery $context
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
            $ctx.Window.DialogResult=$true
        }catch{[Windows.MessageBox]::Show($ctx.Window,$_.Exception.Message,'应用失败','OK','Error')|Out-Null}
        finally{$sender.IsEnabled=$true}
    })
    $window.Tag=$context;$window.Add_Closed({param($sender,$eventArgs);$ctx=$sender.Tag;Stop-ServerManagerCandidateDiscovery $ctx;Clear-ServerPulseSessionSecrets $ctx.SessionSecrets;foreach($pending in @($ctx.PendingCredentialWrites.Values)){$pending.Password=$null};$ctx.PendingCredentialWrites.Clear()})
    if($SmokeTest){return [PSCustomObject]@{Window=$window;Context=$context;ApplyButton=$apply;AddButton=$add}}
    [void]$window.ShowDialog()
}
