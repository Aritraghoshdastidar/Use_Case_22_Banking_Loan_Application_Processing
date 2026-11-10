# Live smoke test for loan-notification-proc: the outbox sweeper and the decision consumer.
# Needs the Docker stack and the system API, intake API and notification app running (scripts\run-chain.ps1).
#   powershell -File scripts\smoke-notification.ps1
$ErrorActionPreference = 'Continue'
$intake = 'http://localhost:8702/api'
$mq = 'http://localhost:15672/api'
$cred = 'loan:loan'                    # throwaway local RabbitMQ user from docker-compose
$tmp = Join-Path $env:TEMP 'loan-smoke-notification'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
$run = Get-Date -Format 'HHmmss'

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }
function Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }
function MqGet($path) { curl.exe -s -u $cred "$mq/$path" | ConvertFrom-Json }
function MqPost($path, $obj) {
    $f = Join-Path $tmp 'mq.json'; [IO.File]::WriteAllText($f, (Json $obj))
    curl.exe -s -u $cred -X POST "$mq/$path" -H 'Content-Type: application/json' --data-binary "@$f"
}
function QueueDepth($q) { (MqGet "queues/%2F/$q").messages }
function Publish($queue, $payload) {
    MqPost 'exchanges/%2F/loan.exchange/publish' @{ properties = @{ delivery_mode = 2; content_type = 'application/json' }; routing_key = $queue; payload = $payload; payload_encoding = 'string' } | Out-Null
}
function PeekQueue($q, $n, $remove) {
    $mode = if ($remove) { 'ack_requeue_false' } else { 'ack_requeue_true' }
    MqPost "queues/%2F/$q/get" @{ count = $n; ackmode = $mode; encoding = 'auto' } | ConvertFrom-Json
}
function WaitFor($scriptBlock, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $scriptBlock) { return $true }; Start-Sleep 1 }
    return $false
}
function Envelope($id, $appId, $type) {
    Json @{ messageId = $id; correlationId = [guid]::NewGuid().ToString(); applicationId = $appId; type = $type; attempt = 1; createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
}

Check 'notification app is up' (curl.exe -s -o NUL -w "%{http_code}" http://localhost:8705/api/health) 200

# ---- sweeper: an application written by the intake API reaches loan.verify.q
# The document app consumes loan.verify.q for real, so the queue never holds the message. A temporary queue bound to the
# same exchange and routing key receives its own copy to look at.
$spy = 'loan.verify.spy'
$qf = Join-Path $tmp 'spy-queue.json'; [IO.File]::WriteAllText($qf, '{"durable":false,"auto_delete":false}')
$bf = Join-Path $tmp 'spy-binding.json'; [IO.File]::WriteAllText($bf, '{"routing_key":"loan.verify.q"}')
curl.exe -s -u $cred -X PUT "$mq/queues/%2F/$spy" -H 'Content-Type: application/json' --data-binary "@$qf" | Out-Null
curl.exe -s -u $cred -X POST "$mq/bindings/%2F/e/loan.exchange/q/$spy" -H 'Content-Type: application/json' --data-binary "@$bf" | Out-Null
$verifyBefore = QueueDepth $spy
$body = Json @{
    requestId = "SMOKEN-$run-1"; productCode = 'PL'; amount = 200000; tenureMonths = 24
    applicant = @{ fullName = 'Smoke Notification'; dateOfBirth = '1990-05-15'; identityRef = 'ABCDE1234F'; email = 'smoke@example.com'; monthlyIncome = 90000; monthlyObligations = 10000; employmentMonths = 48 }
    documents = @{ folder = 'complete-ok'; documentCount = 4; documents = @(@{ fileName = 'id_proof.pdf'; type = 'ID_PROOF' }) }
}
$f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
$resp = curl.exe -s -X POST "$intake/applications" -H 'Content-Type: application/json' --data-binary "@$f" | ConvertFrom-Json
$appId = $resp.applicationId
Check 'intake accepted the application' ([bool]$appId) $true
$msgId = Sql "SELECT id FROM outbox WHERE payload->>'applicationId' = '$appId'"
Check 'outbox row was written with the application' ([bool]$msgId) $true
$sent = WaitFor { (Sql "SELECT status FROM outbox WHERE id = '$msgId'") -eq 'SENT' } 40
Check 'sweeper marked the outbox row SENT' $sent $true
Check 'outbox row has one attempt' (Sql "SELECT attempts FROM outbox WHERE id = '$msgId'") 1
Check 'loan.verify.q gained exactly one message' (WaitFor { ((QueueDepth $spy) - $verifyBefore) -eq 1 } 15) $true
$peek = PeekQueue $spy 100 $false
$mine = @($peek | Where-Object { $_.payload -like "*$msgId*" })
Check 'the message on the queue is the outbox row' $mine.Count 1
Check 'message is persistent' $mine[0].properties.delivery_mode 2
Check 'message carries the messageId property' $mine[0].properties.message_id $msgId
Check 'message body has the application id' (($mine[0].payload | ConvertFrom-Json).applicationId) $appId
Start-Sleep 7
Check 'a second sweep does not publish it again' (@(PeekQueue $spy 100 $false | Where-Object { $_.payload -like "*$msgId*" }).Count) 1
curl.exe -s -u $cred -X DELETE "$mq/queues/%2F/$spy" | Out-Null

# ---- consumer: loan.decision.q
$dlqBefore = QueueDepth 'loan.decision.q.dlq'
$m1 = [guid]::NewGuid().ToString()
Publish 'loan.decision.q' (Envelope $m1 $appId 'DECISION_READY')
$claimed = WaitFor { (Sql "SELECT count(*) FROM processed_messages WHERE message_id = '$m1'") -eq '1' } 20
Check 'a valid decision message is claimed and handled' $claimed $true
Check 'queue is drained after handling' (WaitFor { (QueueDepth 'loan.decision.q') -eq 0 } 10) $true
Check 'nothing reached the dead-letter queue' ((QueueDepth 'loan.decision.q.dlq') - $dlqBefore) 0

Publish 'loan.decision.q' (Envelope $m1 $appId 'DECISION_READY')
Check 'redelivery of the same message is acknowledged' (WaitFor { (QueueDepth 'loan.decision.q') -eq 0 } 10) $true
Start-Sleep 2
Check 'redelivery is not processed twice' (Sql "SELECT count(*) FROM processed_messages WHERE message_id = '$m1'") 1
Check 'redelivery does not reach the dead-letter queue' ((QueueDepth 'loan.decision.q.dlq') - $dlqBefore) 0

Publish 'loan.decision.q' 'this is not json'
Check 'a poison message is dead-lettered' (WaitFor { ((QueueDepth 'loan.decision.q.dlq') - $dlqBefore) -eq 1 } 15) $true
Publish 'loan.decision.q' (Json @{ messageId = [guid]::NewGuid().ToString(); type = 'DECISION_READY' })
Check 'an envelope with no application id is dead-lettered' (WaitFor { ((QueueDepth 'loan.decision.q.dlq') - $dlqBefore) -eq 2 } 15) $true

$m3 = [guid]::NewGuid().ToString()
Publish 'loan.decision.q' (Envelope $m3 'APP-DOES-NOT-EXIST' 'DECISION_READY')
Check 'an unknown application is dead-lettered without retries' (WaitFor { ((QueueDepth 'loan.decision.q.dlq') - $dlqBefore) -eq 3 } 15) $true
Check 'its claim was released so it can be replayed' (Sql "SELECT count(*) FROM processed_messages WHERE message_id = '$m3'") 0
Check 'main queue is empty at the end' (WaitFor { (QueueDepth 'loan.decision.q') -eq 0 } 10) $true

$dead = PeekQueue 'loan.decision.q.dlq' 50 ($dlqBefore -eq 0)          # removes them: these are only this run's messages
$byId = @($dead | Where-Object { $_.payload -like "*$m3*" })
Check 'dead-letter message keeps the original body' $byId.Count 1
Check 'dead-letter message states why' ($byId[0].properties.headers.'x-failure') 'PERMANENT'
Check 'dead-letter message names the source queue' ($byId[0].properties.headers.'x-source-queue') 'loan.decision.q'
Check 'poison message is marked POISON' (@($dead | Where-Object { $_.properties.headers.'x-failure' -eq 'POISON' }).Count) 2

# clean up what this run created
Sql "DELETE FROM processed_messages WHERE message_id = '$m1'" | Out-Null
Write-Host ''
if ($fail -eq 0) { Write-Host 'All notification checks passed.' -ForegroundColor Green } else { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
