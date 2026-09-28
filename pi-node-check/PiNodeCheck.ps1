<#
  파이 노드 자가진단 스크립트 (읽기 전용 - 설정을 바꾸지 않음)
  실행: 같은 폴더의 "노드점검_실행.bat" 을 마우스 오른쪽 > 관리자 권한으로 실행
  결과: 이 스크립트가 있는 폴더(USB)에 PiNodeReport_컴퓨터이름_날짜.txt 생성
#>

$ErrorActionPreference = 'SilentlyContinue'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp  = Get-Date -Format 'yyyyMMdd_HHmm'
$report = Join-Path $here "PiNodeReport_$($env:COMPUTERNAME)_$stamp.txt"
$ports  = 31400..31409
$issues = New-Object System.Collections.Generic.List[string]

function Section($title) { "`r`n==================== $title ====================" }
function Run($cmd) { try { (Invoke-Expression $cmd 2>&1 | Out-String).TrimEnd() } catch { "실패: $_" } }

$out = New-Object System.Collections.Generic.List[string]
$out.Add("파이 노드 진단 보고서  $(Get-Date)  PC=$($env:COMPUTERNAME)")

# 1. 관리자 권한
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out.Add((Section '1. 관리자 권한'))
$out.Add("관리자 실행: $isAdmin")
if (-not $isAdmin) { $issues.Add('관리자 권한이 아니라 방화벽/전원 항목 일부가 누락될 수 있음') }

# 2. Windows / 가동 시간 / 시간 동기화
$os = Get-CimInstance Win32_OperatingSystem
$uptime = (Get-Date) - $os.LastBootUpTime
$out.Add((Section '2. Windows / 가동시간 / 시계'))
$out.Add("OS: $($os.Caption) $($os.Version)")
$out.Add("마지막 부팅: $($os.LastBootUpTime)  (가동 $([int]$uptime.TotalHours)시간)")
$out.Add((Run 'w32tm /query /status'))
if ($uptime.TotalHours -lt 24) { $issues.Add("최근 $([int]$uptime.TotalHours)시간 전에 재부팅됨 - 정전/업데이트 재시작 여부 확인") }

# 3. 전원 / 절전
$out.Add((Section '3. 전원 설정 (절전 진입 시 노드 중단)'))
$out.Add((Run 'powercfg /getactivescheme'))
$out.Add((Run 'powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE'))
$out.Add((Run 'powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE'))
$sleepAc = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String '0x[0-9a-fA-F]{8}' | Select-Object -Last 2 | Select-Object -First 1)
if ($sleepAc -and ($sleepAc.ToString() -notmatch '0x00000000')) { $issues.Add('전원 연결 시 절전 모드가 켜져 있음 -> "절대 안 함"으로 변경 필요') }

# 4. 설치된 Pi Node / Docker 버전
$out.Add((Section '4. 설치 프로그램 버전'))
$apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -match 'Pi Network|Pi Node|Docker' } |
        Select-Object DisplayName, DisplayVersion, InstallDate
$out.Add(($apps | Format-Table -AutoSize | Out-String).TrimEnd())
if (-not ($apps | Where-Object DisplayName -match 'Pi')) { $issues.Add('Pi Network 데스크탑 설치 정보를 찾지 못함') }

# 5. WSL / Docker 엔진
$out.Add((Section '5. WSL / Docker'))
$out.Add((Run 'wsl --status'))
$out.Add((Run 'wsl -l -v'))
$dockerVer = Run 'docker version --format "{{.Server.Version}}"'
$out.Add("Docker 엔진: $dockerVer")
if ($dockerVer -notmatch '^\d') { $issues.Add('Docker 엔진에 연결 안 됨 (Docker Desktop 미실행 또는 WSL 문제)') }

# 6. 컨테이너 상태 / 노드 동기화
$out.Add((Section '6. 컨테이너'))
$out.Add((Run 'docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'))
$names = docker ps --format '{{.Names}}'
if (-not $names) { $issues.Add('실행 중인 Docker 컨테이너가 없음 -> 노드가 실제로 돌지 않음') }
foreach ($n in $names) {
    $out.Add("`r`n--- [$n] 재시작 횟수 / 시작 시각 ---")
    $out.Add((Run "docker inspect -f 'RestartCount={{.RestartCount}} StartedAt={{.State.StartedAt}}' $n"))
    $info = Run "docker exec $n stellar-core http-command info"
    if ($info -match 'ledger|state') {
        $out.Add("--- [$n] stellar-core info ---")
        $out.Add($info)
        if ($info -notmatch 'Synced!') { $issues.Add("컨테이너 $n 의 블록체인 상태가 'Synced!' 가 아님") }
        $out.Add((Run "docker exec $n stellar-core http-command peers"))
    }
    $out.Add("--- [$n] 최근 로그 40줄 ---")
    $out.Add((Run "docker logs --tail 40 $n"))
}

# 7. 포트 31400-31409 수신 대기
$out.Add((Section '7. 로컬 포트 31400-31409 수신 대기'))
$listen = Get-NetTCPConnection -State Listen | Where-Object { $ports -contains $_.LocalPort }
$out.Add(($listen | Select-Object LocalAddress, LocalPort, OwningProcess | Sort-Object LocalPort | Format-Table -AutoSize | Out-String).TrimEnd())
$missing = $ports | Where-Object { ($listen.LocalPort) -notcontains $_ }
if ($missing) { $issues.Add("수신 대기하지 않는 포트: $($missing -join ', ')") }

# 8. Windows 방화벽
$out.Add((Section '8. Windows 방화벽'))
$out.Add((Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction | Format-Table -AutoSize | Out-String).TrimEnd())
$fw = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Where-Object {
        $pf = $_ | Get-NetFirewallPortFilter
        ($pf.LocalPort -match '314\d\d') }
$out.Add("314xx 허용 인바운드 규칙:")
$out.Add(($fw | Select-Object DisplayName, Profile | Format-Table -AutoSize | Out-String).TrimEnd())
if (-not $fw) { $issues.Add('31400-31409 포트 기준 인바운드 허용 규칙이 없음 (프로그램 기준 규칙이 있을 수 있으니 보고서 확인)') }
$prof = Get-NetConnectionProfile
$out.Add(($prof | Select-Object Name, InterfaceAlias, NetworkCategory | Format-Table -AutoSize | Out-String).TrimEnd())

# 9. 네트워크 / 공유기 (유플러스 이중 NAT 확인)
$out.Add((Section '9. 네트워크 / 공유기'))
$out.Add((Run 'ipconfig /all'))
$route = Run 'tracert -d -h 4 -w 1000 8.8.8.8'
$out.Add($route)
$privHops = ([regex]::Matches($route, '\s(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+)\s*$', 'Multiline')).Count
$out.Add("사설 IP 홉 수: $privHops")
if ($privHops -ge 2) { $issues.Add("공유기 안에 공유기(이중 NAT) 의심 - 사설 IP 구간 $privHops 개. 두 공유기 모두 포트포워딩 필요") }
$pub = try { (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10) } catch { '확인 실패' }
$out.Add("외부(공인) IP: $pub")
$lan = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway }).IPv4Address.IPAddress
$out.Add("이 PC 내부 IP: $lan  <- 공유기 포트포워딩 대상 IP 와 같아야 함")

# 10. 외부에서 포트가 열려 있는지 (공인 IP 로 접속 시도; 공유기 헤어핀 미지원이면 실패할 수 있음)
$out.Add((Section '10. 공인 IP 로 포트 접속 시도 (참고용)'))
if ($pub -match '^\d') {
    foreach ($p in $ports) {
        $t = New-Object Net.Sockets.TcpClient
        $ok = try { $t.ConnectAsync($pub, $p).Wait(2000) -and $t.Connected } catch { $false }
        $t.Close()
        $out.Add("$pub`:$p -> $(if ($ok) {'열림'} else {'응답 없음'})")
    }
    $out.Add('※ 정확한 판정은 휴대폰 LTE(와이파이 끔)로 https://www.yougetsignal.com/tools/open-ports/ 에서 31401 확인')
}

# 요약
$out.Insert(1, "`r`n#### 자동 판정 요약 (문제 후보 $($issues.Count)건) ####`r`n" + (($issues | ForEach-Object { " - $_" }) -join "`r`n") + "`r`n")
$out | Out-File -FilePath $report -Encoding UTF8
Write-Host "`n완료. 보고서: $report" -ForegroundColor Green
Write-Host "문제 후보 $($issues.Count)건:" -ForegroundColor Yellow
$issues | ForEach-Object { Write-Host " - $_" }
