Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:serverPulseLanguageMode = 'zh'
$script:serverPulseResolvedLanguage = 'zh'

$script:serverPulseLanguageResources = @{
    zh = @{
        'language.zh'='中文'; 'language.en'='English'; 'language.system'='跟随系统'; 'language.button.zh'='中'; 'language.button.en'='EN'; 'language.button.system'='系统'; 'language.tooltip'='界面语言：{0}'
        'theme.light'='亮'; 'theme.dark'='暗'; 'theme.system'='跟随系统'; 'theme.button.light'='亮'; 'theme.button.dark'='暗'; 'theme.button.system'='系统'; 'theme.tooltip'='界面主题：{0}'
        'main.connecting'='连接中'; 'main.unmonitored'='未监视'; 'main.waiting'='等待首次采集'; 'main.noneSelected'='尚未选择监视服务器'; 'main.authWaiting'='所选服务器正在等待认证'; 'main.manage'='管理'; 'main.history'='记录'; 'main.refresh'='刷新'; 'main.seconds'='s'; 'main.resize'='拖动右下角调节尺寸'; 'main.tray.hide'='隐藏到托盘'; 'main.tray.exit'='退出'; 'main.tray.show'='显示窗口'; 'main.tray.ssh'='SSH 服务器...'; 'main.theme'='界面主题'; 'main.language'='界面语言'; 'main.edge'='贴边自动隐藏'; 'main.pin'='始终置顶'; 'main.dialog.ok'='知道了'; 'main.historyErrorTitle'='历史记录错误'; 'main.historyErrorMessage'='无法打开占用记录，主监控仍会继续运行。'; 'main.historyErrorFallback'='无法打开占用记录。'; 'main.uiError'='界面操作发生异常，软件已保持运行'; 'main.collectorStartError'='采集器启动失败：{0}'; 'main.collectorError'='采集器错误：{0}'; 'main.collectorRestart'='采集器意外退出，正在重启'; 'main.noData'='采集器未返回数据'; 'main.host'='SSH  {0}'; 'main.gpuWaiting'='GPU · 等待数据'; 'main.gpuNoMetrics'='GPU · 暂无指标'; 'main.gpuSummary'='GPU  {0} 块   ·   总显存 {1} / {2}'; 'main.gpuMemory'='显存  {0} / {1}'; 'main.sshMeta'='{0}   ·   {1} ms   ·   LOAD {2:0.00}'; 'main.tooltipUser'='悬停查看用户占用，单击固定'; 'main.tooltipUserPartial'='用户归属不完整；悬停查看，单击固定'; 'main.tooltipUserUnavailable'='当前无法读取用户归属'; 'main.userHeader'='用户占用'; 'main.userPreview'='悬停预览'; 'main.userPinned'='已固定'; 'main.userUnavailable'='用户归属不可用'; 'main.userPartial'='用户归属部分可用'; 'main.userNoUsers'='暂无正占用用户'; 'main.userOther'='其他（{0} 个用户）'; 'main.userExpand'='展开全部'; 'main.userCollapse'='收起'; 'main.userSystem'='系统/未归属'; 'main.userUnmapped'='未映射进程 {0} 个'; 'main.userNoDetails'='该分钟尚未记录用户明细'; 'main.userPartialNote'='部分采集 · {0}'; 'main.userUnavailableNote'='数据不可用'; 'main.retryState'='● {0} 秒后重试'; 'main.retryPaused'='● 重试已暂停'; 'main.status.online'='● 在线'; 'main.status.authRequired'='● 待认证'; 'main.status.authFailed'='● 认证暂停'; 'main.status.fingerprintWait'='● 待确认指纹'; 'main.status.fingerprintChanged'='● 指纹异常'; 'main.status.connecting'='● 连接中'; 'main.status.offline'='● 离线'; 'main.retryError'='{0}`n下次自动重试：{1}（连续失败 {2} 次）'; 'main.circuitError'='{0}`n已停止自动连接；请打开「管理」并点击「重新检测」。'; 'main.later'='稍后'; 'main.statusError'='● {0}'; 'main.cpu'='CPU'; 'main.memory'='MEM'; 'main.gpu'='GPU'; 'main.vram'='VRAM'; 'main.temperature'='温度';
        'history.title'='占用记录'; 'history.archive'='MINUTE ARCHIVE'; 'history.start'='开始'; 'history.end'='结束'; 'history.year'='年'; 'history.month'='月'; 'history.day'='日'; 'history.hour'='时'; 'history.minute'='分'; 'history.query'='查询'; 'history.recentHour'='最近 1 小时'; 'history.footer'='默认显示最近一小时 · 分钟平均值'; 'history.footerFull'='本地按分钟平均保存 CPU、MEM、LOAD、GPU、显存、温度、功耗与风扇'; 'history.range.invalid'='请修正红色时间字段'; 'history.range.reversed'='结束时间不能早于开始时间'; 'history.range.count'='{0} 个分钟点 · {1} 分钟'; 'history.error'='查询失败'; 'history.errorHint'='请检查本地历史记录文件后重试'; 'history.readError'='无法读取占用记录`n{0}'; 'history.noUsers'='该分钟尚未记录用户明细'; 'history.partial'='部分采集 · {0}'; 'history.gpuVram'='VRAM'; 'history.gpuUtil'='GPU'; 'history.temp'='TEMP';
        'manager.title'='Server Pulse · SSH 服务器'; 'manager.intro'='选择需要监视的 SSH 服务器。已验证服务器立即运行；缺少认证的服务器保持暂停，不影响其他服务器。'; 'manager.discovered'='已发现 {0} 个 SSH 配置项'; 'manager.waitingDiscovery'='等待发现 SSH 配置'; 'manager.discovering'='正在后台发现 SSH 配置…'; 'manager.noNew'='未发现新的 SSH 配置项'; 'manager.discoveryFailed'='SSH 配置发现失败，可继续手动添加'; 'manager.add'='添加服务器'; 'manager.apply'='验证并应用'; 'manager.cancel'='取消'; 'manager.edit'='编辑'; 'manager.delete'='删除'; 'manager.updatePassword'='更新密码'; 'manager.deleteCredential'='删除凭据'; 'manager.recheck'='重新检测'; 'manager.passwordless'='免密登录'; 'manager.saved'='已保存'; 'manager.sessionOnly'='仅本次'; 'manager.noCredential'='无凭据'; 'manager.savedPending'='已保存（待应用）'; 'manager.noCredentialPending'='无凭据（待应用）'; 'manager.notVerified'='尚未验证'; 'manager.online'='在线'; 'manager.passwordlessStatus'='免密已验证'; 'manager.connectionUnavailable'='连接暂不可用'; 'manager.authRequired'='需要认证'; 'manager.authFailed'='认证失败'; 'manager.hostUnknown'='待确认主机指纹'; 'manager.hostChanged'='主机指纹异常'; 'manager.testing'='检测中…'; 'manager.testFailed'='检测失败'; 'manager.networkError'='网络错误'; 'manager.addTitle'='添加 SSH 服务器'; 'manager.editTitle'='编辑 SSH 服务器'; 'manager.displayName'='显示名称'; 'manager.host'='主机或 IP'; 'manager.port'='端口'; 'manager.user'='用户名'; 'manager.save'='保存'; 'manager.inherit'='继承原服务器历史'; 'manager.inheritTip'='取消后会生成新的服务器 ID；旧历史仍保留到期。若连接到不同物理服务器，建议取消。'; 'manager.reveal'='按住显示'; 'manager.saveCredential'='存入 Windows 凭据管理器'; 'manager.waitingStatus'='等待验证'; 'manager.firstTrust'='首次连接无法验证服务器身份。请通过可信渠道核对以下 SHA256 指纹：`n`n{0}`n`n确认信任并写入当前用户 known_hosts？'; 'manager.invalidPort'='端口必须是数字'; 'manager.emptyLabel'='显示名称不能为空'; 'manager.inputError'='输入错误'; 'manager.applyError'='应用失败'; 'manager.retryTip'='重新检测会立即解除该服务器的连接退避或熔断';
        'status.unavailable'='连接暂不可用'; 'status.connecting'='正在连接'; 'status.authentication'='待认证'; 'status.paused'='认证暂停'; 'status.fingerprint'='指纹异常';
        'agent.title'='服务器端监控'; 'agent.status.running'='运行中'; 'agent.status.stale'='卡顿'; 'agent.status.stopped'='已停止'; 'agent.status.notInstalled'='未注入'; 'agent.status.unknown'='未知'; 'agent.status.checking'='检测中…'; 'agent.notConfigured'='未配置'; 'agent.inject'='注入'; 'agent.stop'='停止'; 'agent.restart'='重启'; 'agent.config'='配置'; 'agent.merge'='合并记录'; 'agent.uninstall'='卸载'; 'agent.mergeAll'='合并全部'; 'agent.configTitle'='服务器端监控配置'; 'agent.interval'='采样间隔（秒，1–3600）'; 'agent.retention'='服务器端保留天数（1–3650）'; 'agent.autoRestore'='应用启动时自动恢复已停止的监控'; 'agent.save'='保存'; 'agent.uninstallTitle'='卸载服务器端监控'; 'agent.uninstallPrompt'='将停止并删除服务器端「{0}」的 ~/.serverpulse 目录（含全部服务器端记录）。建议先合并记录。确定继续？'; 'agent.mergeTitle'='合并服务器端记录'; 'agent.mergeClean'='合并后清理服务器端已合并记录'; 'agent.mergeRun'='开始合并'; 'agent.mergeSummary'='拉取 {0} 行 · 新增 {1} · 更新 {2} · 跳过 {3} · 未知 {4} · 损坏 {5} · 清理 {6} · 耗时 {7} ms'; 'agent.mergeResult'='合并完成'; 'agent.mergeError'='合并失败：{0}'; 'agent.mergeNothing'='没有需要合并的新记录'; 'agent.mergeAllResult'='合并全部完成：{0} 台成功 / {1} 台失败'; 'agent.injectStarted'='已注入并启动'; 'agent.injectAlready'='已在运行'; 'agent.stopDone'='已停止'; 'agent.restartDone'='已重启'; 'agent.configDone'='配置已更新'; 'agent.uninstallDone'='已卸载'; 'agent.opError'='操作失败：{0}'; 'agent.autoMerge'='启动时自动合并服务器端记录'; 'agent.hint'='在服务器 home 目录下注入常驻采集代理，应用关闭后仍持续记录；可随时在此检测状态、控制启停并合并记录到本地历史。';
    }
    en = @{
        'language.zh'='中文'; 'language.en'='English'; 'language.system'='Follow system'; 'language.button.zh'='中'; 'language.button.en'='EN'; 'language.button.system'='SYS'; 'language.tooltip'='Interface language: {0}'
        'theme.light'='Light'; 'theme.dark'='Dark'; 'theme.system'='Follow system'; 'theme.button.light'='Light'; 'theme.button.dark'='Dark'; 'theme.button.system'='SYS'; 'theme.tooltip'='Interface theme: {0}'
        'main.connecting'='Connecting'; 'main.unmonitored'='Not monitored'; 'main.waiting'='Waiting for first sample'; 'main.noneSelected'='No monitored servers selected'; 'main.authWaiting'='Selected servers are waiting for authentication'; 'main.manage'='Manage'; 'main.history'='History'; 'main.refresh'='Refresh'; 'main.seconds'='s'; 'main.resize'='Drag the lower-right corner to resize'; 'main.tray.hide'='Hide to tray'; 'main.tray.exit'='Exit'; 'main.tray.show'='Show window'; 'main.tray.ssh'='SSH servers...'; 'main.theme'='Interface theme'; 'main.language'='Interface language'; 'main.edge'='Auto-hide at edge'; 'main.pin'='Always on top'; 'main.dialog.ok'='OK'; 'main.historyErrorTitle'='History error'; 'main.historyErrorMessage'='Unable to open usage history. Monitoring will continue.'; 'main.historyErrorFallback'='Unable to open usage history.'; 'main.uiError'='A UI action failed; the application is still running'; 'main.collectorStartError'='Collector failed to start: {0}'; 'main.collectorError'='Collector error: {0}'; 'main.collectorRestart'='Collector exited unexpectedly; restarting'; 'main.noData'='Collector returned no data'; 'main.host'='SSH  {0}'; 'main.gpuWaiting'='GPU · Waiting for data'; 'main.gpuNoMetrics'='GPU · No metrics'; 'main.gpuSummary'='GPU  {0} cards   ·   VRAM {1} / {2}'; 'main.gpuMemory'='VRAM  {0} / {1}'; 'main.sshMeta'='{0}   ·   {1} ms   ·   LOAD {2:0.00}'; 'main.tooltipUser'='Hover for user usage; click to pin'; 'main.tooltipUserPartial'='User attribution is partial; hover to inspect'; 'main.tooltipUserUnavailable'='User attribution is unavailable'; 'main.userHeader'='User usage'; 'main.userPreview'='Hover preview'; 'main.userPinned'='Pinned'; 'main.userUnavailable'='User attribution unavailable'; 'main.userPartial'='User attribution partial'; 'main.userNoUsers'='No users currently using this resource'; 'main.userOther'='Other ({0} users)'; 'main.userExpand'='Expand all'; 'main.userCollapse'='Collapse'; 'main.userSystem'='System / unattributed'; 'main.userUnmapped'='{0} unmapped processes'; 'main.userNoDetails'='No user details were recorded for this minute'; 'main.userPartialNote'='Partial sample · {0}'; 'main.userUnavailableNote'='Data unavailable'; 'main.retryState'='● Retry in {0}s'; 'main.retryPaused'='● Retry paused'; 'main.status.online'='● Online'; 'main.status.authRequired'='● Auth required'; 'main.status.authFailed'='● Authentication paused'; 'main.status.fingerprintWait'='● Confirm fingerprint'; 'main.status.fingerprintChanged'='● Fingerprint changed'; 'main.status.connecting'='● Connecting'; 'main.status.offline'='● Offline'; 'main.retryError'='{0}`nNext retry: {1} (consecutive failures: {2})'; 'main.circuitError'='{0}`nAutomatic connection stopped; open “Manage” and click “Recheck”.'; 'main.later'='later'; 'main.statusError'='● {0}'; 'main.cpu'='CPU'; 'main.memory'='MEM'; 'main.gpu'='GPU'; 'main.vram'='VRAM'; 'main.temperature'='TEMP';
        'history.title'='Usage history'; 'history.archive'='MINUTE ARCHIVE'; 'history.start'='Start'; 'history.end'='End'; 'history.year'='Y'; 'history.month'='M'; 'history.day'='D'; 'history.hour'='h'; 'history.minute'='min'; 'history.query'='Query'; 'history.recentHour'='Last 1 hour'; 'history.footer'='Last hour by default · minute averages'; 'history.footerFull'='Minute averages saved locally for CPU, MEM, LOAD, GPU, VRAM, temperature, power and fan'; 'history.range.invalid'='Fix the red time fields'; 'history.range.reversed'='End time cannot be earlier than start time'; 'history.range.count'='{0} minute points · {1} minutes'; 'history.error'='Query failed'; 'history.errorHint'='Check the local history files and try again'; 'history.readError'='Unable to read usage history`n{0}'; 'history.noUsers'='No user details were recorded for this minute'; 'history.partial'='Partial sample · {0}'; 'history.gpuVram'='VRAM'; 'history.gpuUtil'='GPU'; 'history.temp'='TEMP';
        'manager.title'='Server Pulse · SSH servers'; 'manager.intro'='Choose SSH servers to monitor. Verified servers run immediately; servers missing authentication stay paused without blocking others.'; 'manager.discovered'='{0} SSH config entries found'; 'manager.waitingDiscovery'='Waiting to discover SSH config'; 'manager.discovering'='Discovering SSH config in the background…'; 'manager.noNew'='No new SSH config entries found'; 'manager.discoveryFailed'='SSH config discovery failed; you can still add a server manually'; 'manager.add'='Add server'; 'manager.apply'='Verify and apply'; 'manager.cancel'='Cancel'; 'manager.edit'='Edit'; 'manager.delete'='Delete'; 'manager.updatePassword'='Update password'; 'manager.deleteCredential'='Delete credential'; 'manager.recheck'='Recheck'; 'manager.passwordless'='Passwordless login'; 'manager.saved'='Saved'; 'manager.sessionOnly'='This session'; 'manager.noCredential'='No credential'; 'manager.savedPending'='Saved (pending)'; 'manager.noCredentialPending'='No credential (pending)'; 'manager.notVerified'='Not verified'; 'manager.online'='Online'; 'manager.passwordlessStatus'='Passwordless verified'; 'manager.connectionUnavailable'='Connection unavailable'; 'manager.authRequired'='Authentication required'; 'manager.authFailed'='Authentication failed'; 'manager.hostUnknown'='Host fingerprint needs confirmation'; 'manager.hostChanged'='Host fingerprint changed'; 'manager.testing'='Testing…'; 'manager.testFailed'='Test failed'; 'manager.networkError'='Network error'; 'manager.addTitle'='Add SSH server'; 'manager.editTitle'='Edit SSH server'; 'manager.displayName'='Display name'; 'manager.host'='Host or IP'; 'manager.port'='Port'; 'manager.user'='User name'; 'manager.save'='Save'; 'manager.inherit'='Inherit existing server history'; 'manager.inheritTip'='Uncheck to create a new server ID; old history remains until retention. Uncheck when this is a different machine.'; 'manager.reveal'='Hold to show'; 'manager.saveCredential'='Save in Windows Credential Manager'; 'manager.waitingStatus'='Waiting for verification'; 'manager.firstTrust'='The server identity could not be verified on first connection. Check this SHA256 fingerprint through a trusted channel:`n`n{0}`n`nTrust it and write it to the current user known_hosts?'; 'manager.invalidPort'='Port must be numeric'; 'manager.emptyLabel'='Display name cannot be empty'; 'manager.inputError'='Input error'; 'manager.applyError'='Apply failed'; 'manager.retryTip'='Recheck immediately clears the server retry backoff or circuit breaker';
        'status.unavailable'='Connection unavailable'; 'status.connecting'='Connecting'; 'status.authentication'='Authentication required'; 'status.paused'='Authentication paused'; 'status.fingerprint'='Fingerprint error';
        'agent.title'='Server-side monitoring'; 'agent.status.running'='Running'; 'agent.status.stale'='Stale'; 'agent.status.stopped'='Stopped'; 'agent.status.notInstalled'='Not installed'; 'agent.status.unknown'='Unknown'; 'agent.status.checking'='Checking…'; 'agent.notConfigured'='Not configured'; 'agent.inject'='Inject'; 'agent.stop'='Stop'; 'agent.restart'='Restart'; 'agent.config'='Configure'; 'agent.merge'='Merge records'; 'agent.uninstall'='Uninstall'; 'agent.mergeAll'='Merge all'; 'agent.configTitle'='Server-side monitoring config'; 'agent.interval'='Sample interval (seconds, 1-3600)'; 'agent.retention'='Server-side retention (days, 1-3650)'; 'agent.autoRestore'='Auto-restore stopped monitoring on app startup'; 'agent.save'='Save'; 'agent.uninstallTitle'='Uninstall server-side monitoring'; 'agent.uninstallPrompt'='This stops and removes the ~/.serverpulse directory (including all server-side records) on "{0}". Merging records first is recommended. Continue?'; 'agent.mergeTitle'='Merge server records'; 'agent.mergeClean'='Clean merged server records after merge'; 'agent.mergeRun'='Start merge'; 'agent.mergeSummary'='Pulled {0} lines · Added {1} · Updated {2} · Skipped {3} · Unknown {4} · Corrupt {5} · Cleaned {6} · {7} ms'; 'agent.mergeResult'='Merge finished'; 'agent.mergeError'='Merge failed: {0}'; 'agent.mergeNothing'='No new records to merge'; 'agent.mergeAllResult'='Merge all finished: {0} succeeded / {1} failed'; 'agent.injectStarted'='Injected and started'; 'agent.injectAlready'='Already running'; 'agent.stopDone'='Stopped'; 'agent.restartDone'='Restarted'; 'agent.configDone'='Config updated'; 'agent.uninstallDone'='Uninstalled'; 'agent.opError'='Operation failed: {0}'; 'agent.autoMerge'='Auto-merge server records on startup'; 'agent.hint'='Injects a persistent sampling agent into the server home directory that keeps recording while the app is closed; check status, control it, and merge records into local history here.';
    }
}

foreach ($language in @('zh','en')) {
    $r = $script:serverPulseLanguageResources[$language]
    $r['main.summaryCount'] = if ($language -eq 'zh') { '{0} / {1} 在线   ·   {2} GPU' } else { '{0} / {1} online   ·   {2} GPU' }
    $r['main.fleetCount'] = if ($language -eq 'zh') { '  {0} / {1} 在线' } else { '  {0} / {1} online' }
    $r['main.fleetAllOnline'] = if ($language -eq 'zh') { '  全部在线' } else { '  All online' }
    $r['main.unknownUser'] = if ($language -eq 'zh') { '未知用户' } else { 'Unknown user' }
    $r['main.userComplete'] = if ($language -eq 'zh') { '归属数据完整' } else { 'Attribution complete' }
    $r['main.userPartialStatus'] = if ($language -eq 'zh') { '部分归属 · 未读取项计入未归属' } else { 'Partial attribution · unreadable items are unattributed' }
    $r['main.userMemoryFoot'] = if ($language -eq 'zh') { 'RSS 估算 · 共享页可能重复（约 {0:0.0} GB）' } else { 'RSS estimate · shared pages may be counted twice (about {0:0.0} GB)' }
    $r['main.userMemoryFootShort'] = if ($language -eq 'zh') { 'RSS 快速估算 · 共享页可能重复计入' } else { 'Fast RSS estimate · shared pages may be counted twice' }
    $r['main.userVramFoot'] = if ($language -eq 'zh') { '逐卡显存 · 驱动与未映射占用归入未归属' } else { 'Per-card VRAM · driver and unmapped usage is unattributed' }
    $r['main.userCpuFoot'] = if ($language -eq 'zh') { 'CPU 按整台服务器 0–100% 归一化' } else { 'CPU normalized to 0–100% of the whole server' }
    $r['main.opacity'] = if ($language -eq 'zh') { '背景透明度' } else { 'Background opacity' }
    $r['main.refreshTip'] = if ($language -eq 'zh') { '刷新间隔：1–300 秒，回车生效' } else { 'Refresh interval: 1–300 seconds; press Enter to apply' }
    $r['main.serverButton'] = if ($language -eq 'zh') { '选择监视 SSH 服务器' } else { 'Choose monitored SSH servers' }
    $r['main.logDetail'] = if ($language -eq 'zh') { '详细日志：{0}' } else { 'Detailed log: {0}' }
    $r['main.dialogOk'] = if ($language -eq 'zh') { '知道了' } else { 'OK' }
    $r['main.trayTitle'] = if ($language -eq 'zh') { 'Server Pulse - SSH 资源监控' } else { 'Server Pulse - SSH resource monitor' }
    $r['main.logTooltip'] = if ($language -eq 'zh') { '错误详情已写入 {0}' } else { 'Error details written to {0}' }
    $r['main.historyWriteError'] = if ($language -eq 'zh') { '历史记录失败：{0}' } else { 'History write failed: {0}' }
    $r['main.authNotificationTitle'] = if ($language -eq 'zh') { 'Server Pulse 需要处理 SSH 认证' } else { 'Server Pulse needs SSH authentication' }
    $r['manager.passwordlessTip'] = if ($language -eq 'zh') { '免密登录会使用 SSH 密钥或 ssh-agent；保存的 Windows 凭据只供 Server Pulse 使用，终端 ssh 不会自动读取。重新检测可验证免密。' } else { 'Passwordless login uses SSH keys or ssh-agent. Saved Windows credentials are used only by Server Pulse; terminal ssh does not read them automatically. Recheck to verify passwordless access.' }
    $r['history.detailCpu'] = if ($language -eq 'zh') { '归属 {0:0.##}% · 重叠 {1:0.##}% · 跳过 {2:0.##}' } else { 'Attributed {0:0.##}% · overlap {1:0.##}% · skipped {2:0.##}' }
    $r['history.detailMemory'] = if ($language -eq 'zh') { '归属 {0} · 重叠 {1} · 跳过 {2:0.##}' } else { 'Attributed {0} · overlap {1} · skipped {2:0.##}' }
    $r['history.detailGpu'] = if ($language -eq 'zh') { '归属 {0} · 未映射进程 {1:0.##}' } else { 'Attributed {0} · {1:0.##} unmapped processes' }
    $r['history.userRemove'] = if ($language -eq 'zh') { '点击移除用户曲线' } else { 'Click to remove user curve' }
    $r['history.popupPinHint'] = if ($language -eq 'zh') { '单击曲线固定弹窗' } else { 'Click curve to pin popup' }
    $r['history.popupUnpinHint'] = if ($language -eq 'zh') { '双击曲线解除固定' } else { 'Double-click curve to unpin' }
    $r['history.userCurveHint'] = if ($language -eq 'zh') { '单击查看用户曲线' } else { 'Click to view user curve' }
    $r['history.hideSeries'] = if ($language -eq 'zh') { '点击隐藏 {0}' } else { 'Click to hide {0}' }
    $r['history.showSeries'] = if ($language -eq 'zh') { '点击显示 {0}' } else { 'Click to show {0}' }
    $r['history.legend'] = if ($language -eq 'zh') { '绿 利用率 / CPU / MEM   ·   蓝 显存   ·   橙 温度' } else { 'Green utilization / CPU / MEM   ·   Blue VRAM   ·   Orange temperature' }
    $r['history.gpuSubtitle'] = if ($language -eq 'zh') { '显存 {0:0.0}/{1:0.0} GB · 功耗 {2:0}/{3:0} W · 风扇 {4:0}%' } else { 'VRAM {0:0.0}/{1:0.0} GB · power {2:0}/{3:0} W · fan {4:0}%' }
    $r['history.dateDayTip'] = if ($language -eq 'zh') { '按年、月校验实际天数' } else { 'Day is checked against the selected year and month' }
    $r['history.noRecords'] = if ($language -eq 'zh') { '所选时间段暂无记录' } else { 'No records in the selected time range' }
    $r['history.meta'] = if ($language -eq 'zh') { '{0} · 在线样本 {1}/{2}' } else { '{0} · online samples {1}/{2}' }
    $r['history.settings'] = if ($language -eq 'zh') { '记录设置' } else { 'History settings' }
    $r['history.settingsExpand'] = if ($language -eq 'zh') { '设置' } else { 'Settings' }
    $r['history.retention'] = if ($language -eq 'zh') { '保留时长' } else { 'Retention' }
    $r['history.retentionUnit'] = if ($language -eq 'zh') { '天' } else { 'days' }
    $r['history.retentionTip'] = if ($language -eq 'zh') { '自然日计算，范围 1–3650 天' } else { 'Calendar days, from 1 to 3650' }
    $r['history.neverCleanup'] = if ($language -eq 'zh') { '永不清理' } else { 'Never clean up' }
    $r['history.dataRoot'] = if ($language -eq 'zh') { '数据目录' } else { 'Data directory' }
    $r['history.browse'] = if ($language -eq 'zh') { '浏览' } else { 'Browse' }
    $r['history.settingsApply'] = if ($language -eq 'zh') { '保存并应用' } else { 'Save and apply' }
    $r['history.settingsSaved'] = if ($language -eq 'zh') { '设置已保存：{0}' } else { 'Settings saved: {0}' }
    $r['history.settingsInvalid'] = if ($language -eq 'zh') { '请修正红色设置字段' } else { 'Fix the red settings fields' }
    $r['history.settingsPathInvalid'] = if ($language -eq 'zh') { '数据目录无效：{0}' } else { 'Invalid data directory: {0}' }
    $r['history.settingsPrivacy'] = if ($language -eq 'zh') { '离开默认目录后，历史记录、服务器列表和错误日志将保存到新位置。请确认该目录由你控制。' } else { 'History, server configuration, and error logs will be saved outside the default directory. Confirm that you control this location.' }
    $r['history.settingsFallback'] = if ($language -eq 'zh') { '首选数据目录不可用，当前已回退到默认目录；请重新选择路径。' } else { 'The preferred data directory is unavailable. The default directory is active; choose a path again.' }
    $r['history.settingsPending'] = if ($language -eq 'zh') { '设置待同步到首选目录' } else { 'Settings pending sync to the preferred directory' }
    $r['history.settingsStatusRetention'] = if ($language -eq 'zh') { '保留 {0} 天' } else { 'Retain {0} days' }
    $r['history.settingsStatusNever'] = if ($language -eq 'zh') { '永不清理' } else { 'Never clean up' }
    $r['history.settingsStatusPaused'] = if ($language -eq 'zh') { '清理已暂停' } else { 'Cleanup paused' }
    $r['history.setupTitle'] = if ($language -eq 'zh') { '首次配置记录' } else { 'Set up history storage' }
    $r['history.setupMessage'] = if ($language -eq 'zh') { '请先确认历史保留时长和数据目录。保存设置后才能打开记录页面。' } else { 'Confirm the history retention and data directory before opening the history page.' }
    $r['history.setupSave'] = if ($language -eq 'zh') { '保存设置' } else { 'Save settings' }
    $r['history.setupCancel'] = if ($language -eq 'zh') { '取消' } else { 'Cancel' }
    $r['history.migrationTitle'] = if ($language -eq 'zh') { '迁移记录数据' } else { 'Migrate history data' }
    $r['history.migrationSummary'] = if ($language -eq 'zh') { '源目录：{0}`n目标目录：{1}`n文件数：{2} · 估算大小：{3}' } else { 'Source: {0}`nTarget: {1}`nFiles: {2} · Estimated size: {3}' }
    $r['history.migrationConflict'] = if ($language -eq 'zh') { '目标目录存在同名文件，请选择处理方式。' } else { 'The target contains files with the same names. Choose how to proceed.' }
    $r['history.migrationOverwrite'] = if ($language -eq 'zh') { '覆盖' } else { 'Overwrite' }
    $r['history.migrationMerge'] = if ($language -eq 'zh') { '自动合并' } else { 'Merge' }
    $r['history.migrationCancel'] = if ($language -eq 'zh') { '取消迁移' } else { 'Cancel migration' }
    $r['history.cleanupPrompt'] = if ($language -eq 'zh') { '保留时长缩短后，是否立即清理过期记录？' } else { 'Retention is shorter. Clean up expired records now?' }
    $r['history.cleanupImmediate'] = if ($language -eq 'zh') { '立即清理' } else { 'Clean now' }
    $r['history.cleanupNextStartup'] = if ($language -eq 'zh') { '下次启动清理' } else { 'Clean next startup' }
    $r['history.cleanupNone'] = if ($language -eq 'zh') { '不清理' } else { 'Do not clean' }
    $r['history.cleanupNoneStatus'] = if ($language -eq 'zh') { '已保存新保留时长，自动清理已暂停。' } else { 'The new retention is saved; automatic cleanup is paused.' }
    $r['history.noRecordsRetention'] = if ($language -eq 'zh') { '该时间段无保留记录' } else { 'No retained records in this time range' }
    $r['manager.fingerprintChangedMessage'] = if ($language -eq 'zh') { 'SSH 主机指纹与 known_hosts 不一致，连接已阻断。请先从可信渠道核验，软件不会自动替换。`n`n旧指纹：`n{0}`n`n新指纹：`n{1}`n`n人工确认后参考命令：{2}' } else { 'The SSH host fingerprint does not match known_hosts; the connection was blocked. Verify it through a trusted channel. The software will not replace it automatically.`n`nOld fingerprint:`n{0}`n`nNew fingerprint:`n{1}`n`nReference command after manual verification: {2}' }
    $r['manager.deleteCredentialPrompt'] = if ($language -eq 'zh') { '删除登录身份 {0} 的 Windows 凭据？`n`n受影响服务器：{1}' } else { 'Delete the Windows credential for {0}?`n`nAffected servers: {1}' }
    $r['manager.deleteServerPrompt'] = if ($language -eq 'zh') { '从 Server Pulse 删除「{0}」？旧历史不会删除。' } else { 'Delete "{0}" from Server Pulse? Existing history will be kept.' }
    $r['manager.deleteOnApplyPrompt'] = if ($language -eq 'zh') { '应用删除时，同时从 Windows 凭据管理器删除此登录身份的密码？`n`n受影响服务器：{0}' } else { 'Also delete this login password from Windows Credential Manager when applying?`n`nAffected servers: {0}' }
    $r['manager.identityChangedPrompt'] = if ($language -eq 'zh') { '连接身份已改变，旧密码不会迁移。应用修改时是否删除旧 Windows 凭据？' } else { 'The connection identity changed; the old password will not be migrated. Delete the old Windows credential when applying?' }
    $r['manager.oldCredentialTitle'] = if ($language -eq 'zh') { '旧凭据' } else { 'Old credential' }
    $r['manager.deleteServerTitle'] = if ($language -eq 'zh') { '删除服务器' } else { 'Delete server' }
    $r['manager.deleteCredentialTitle'] = if ($language -eq 'zh') { '删除凭据' } else { 'Delete credential' }
    $r['manager.confirmFingerprintTitle'] = if ($language -eq 'zh') { '确认 SSH 主机指纹' } else { 'Confirm SSH host fingerprint' }
    $r['manager.fingerprintErrorTitle'] = if ($language -eq 'zh') { '主机指纹错误' } else { 'Host fingerprint error' }
}

function Normalize-ServerPulseLanguageMode {
    param([string]$Mode)
    $normalized = if ($null -eq $Mode) { '' } else { $Mode.Trim().ToLowerInvariant() }
    if ($normalized -in @('zh','zh-cn','chinese','中文')) { return 'zh' }
    if ($normalized -in @('en','en-us','english')) { return 'en' }
    if ($normalized -eq 'system') { return 'system' }
    return 'zh'
}

function Get-ServerPulseSystemLanguage {
    try {
        $name = [Globalization.CultureInfo]::CurrentUICulture.Name
        if ($name -match '^en(?:-|$)') { return 'en' }
    } catch { }
    return 'zh'
}

function Resolve-ServerPulseLanguage {
    param([string]$Mode, [ValidateSet('zh','en')][string]$SystemLanguage)
    $normalized = Normalize-ServerPulseLanguageMode $Mode
    if ($normalized -ne 'system') { return $normalized }
    if ($SystemLanguage) { return $SystemLanguage }
    return Get-ServerPulseSystemLanguage
}

function Set-ServerPulseLanguageState {
    param([string]$Mode, [ValidateSet('zh','en')][string]$ResolvedLanguage)
    $script:serverPulseLanguageMode = Normalize-ServerPulseLanguageMode $Mode
    $script:serverPulseResolvedLanguage = if ($ResolvedLanguage) { $ResolvedLanguage } else { Resolve-ServerPulseLanguage $script:serverPulseLanguageMode }
    return $script:serverPulseResolvedLanguage
}

function Get-ServerPulseText {
    param([Parameter(Mandatory)][string]$Key, [object[]]$Arguments)
    $language = if ($script:serverPulseLanguageResources.ContainsKey($script:serverPulseResolvedLanguage)) { $script:serverPulseResolvedLanguage } else { 'zh' }
    $template = $script:serverPulseLanguageResources[$language][$Key]
    if ($null -eq $template) { $template = $script:serverPulseLanguageResources.zh[$Key] }
    if ($null -eq $template) { return $Key }
    $template = ([string]$template).Replace('`n',[Environment]::NewLine)
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return [string]$template }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, [string]$template, [object[]]$Arguments)
}

function Get-ServerPulseLanguageDisplayName {
    param([string]$Mode)
    $normalized = Normalize-ServerPulseLanguageMode $Mode
    return Get-ServerPulseText ("language.{0}" -f $normalized)
}
