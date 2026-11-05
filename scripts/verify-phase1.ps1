# Phase 1 gate: checks the local stack, schema, seed data, queues, mail, and object store.
$ErrorActionPreference = 'Continue'
$fail = 0
function Check($name, [scriptblock]$test) {
    try { $ok = & $test } catch { $ok = $false }
    if ($ok) { Write-Host "[PASS] $name" -ForegroundColor Green } else { Write-Host "[FAIL] $name" -ForegroundColor Red; $script:fail++ }
}
function Psql($sql) { (docker exec loan-postgres psql -U loan -d loan -tA -c $sql) -join '' }

foreach ($c in 'loan-postgres','loan-rabbitmq','loan-minio','loan-mailhog') {
    Check "container $c running" { (docker inspect -f '{{.State.Running}}' $c) -eq 'true' }
}
Check 'schema: 14 base tables'                { [int](Psql "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'") -eq 14 }
Check 'seed: 2 products'                      { [int](Psql 'select count(*) from products') -eq 2 }
Check 'seed: 7 document rules'                { [int](Psql 'select count(*) from product_document_rules') -eq 7 }
Check 'seed: PL needs 2 payslips'             { [int](Psql "select required_count from product_document_rules where product_code='PL' and doc_type='PAYSLIP'") -eq 2 }
Check 'seed: scorecard weights sum to 100'    { [int](Psql "select sum(weight) from scorecard_config where version='SC-1.0'") -eq 100 }
Check 'seed: 4 applicant histories'           { [int](Psql 'select count(*) from applicant_history') -eq 4 }
Check 'seed: bureau_enabled flag'             { (Psql "select flag_value from system_flags where flag_key='bureau_enabled'") -eq 'true' }
Check 'application id format APP-YYYY-NNNNNN' {
    $id = Psql "insert into applications(request_id,payload_hash,correlation_id,product_code,requested_amount,requested_tenure,applicant_name,date_of_birth,identity_ref,email,monthly_income,manifest) values ('verify-tmp','x',gen_random_uuid(),'PL',100000,12,'T','1990-01-01','ABCDE1234F','t@e.com',50000,'{}') returning application_id"
    $script:tmpId = if ($id -match '(APP-\d{4}-\d{6})') { $Matches[1] } else { '' }
    $script:tmpId -ne ''
}
Check 'idempotency: duplicate request_id rejected' {
    (docker exec loan-postgres psql -U loan -d loan -c "insert into applications(request_id,payload_hash,correlation_id,product_code,requested_amount,requested_tenure,applicant_name,date_of_birth,identity_ref,email,monthly_income,manifest) values ('verify-tmp','x',gen_random_uuid(),'PL',100000,12,'T','1990-01-01','ABCDE1234F','t@e.com',50000,'{}')" 2>&1) -match 'duplicate key'
}
Check 'decision_audit is append-only' {
    docker exec loan-postgres psql -U loan -d loan -c "insert into decision_audit(application_id,correlation_id,event,source_app) values ('$script:tmpId',gen_random_uuid(),'RECEIVED','verify')" *> $null
    (docker exec loan-postgres psql -U loan -d loan -c "update decision_audit set event='X'" 2>&1) -match 'append-only'
}
# cleanup: audit rows are immutable by design, so drop the test application's audit via truncate-free path
docker exec loan-postgres psql -U loan -d loan -c "alter table decision_audit disable trigger trg_decision_audit_immutable; delete from decision_audit where source_app='verify'; alter table decision_audit enable trigger trg_decision_audit_immutable; delete from applications where request_id like 'verify-tmp%'; alter sequence application_seq restart 1" *> $null

Check 'rabbitmq: 6 queues (3 + 3 dlq)' {
    $q = Invoke-RestMethod -Uri 'http://localhost:15672/api/queues' -Headers @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('loan:loan'))}
    ($q.name | Where-Object { $_ -like 'loan.*' }).Count -eq 6
}
Check 'mailhog API reachable'                 { (Invoke-RestMethod 'http://localhost:8625/api/v2/messages').total -ge 0 }
Check 'minio live'                            { (Invoke-WebRequest 'http://localhost:9000/minio/health/live' -UseBasicParsing).StatusCode -eq 200 }
Check 'minio bucket loan-docs exists'         {
    $o = docker run --rm -e AWS_ACCESS_KEY_ID=loan -e AWS_SECRET_ACCESS_KEY=loan-secret-123 -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli --endpoint-url http://host.docker.internal:9000 s3 ls 2>&1
    ($o -join ' ') -match 'loan-docs'
}
if ($fail -eq 0) { Write-Host "`nPhase 1 gate: ALL PASSED" -ForegroundColor Green } else { Write-Host "`nPhase 1 gate: $fail FAILED" -ForegroundColor Red }
exit $fail
