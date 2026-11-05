# Copies generated sample folders into the local MinIO bucket under staging/<scenario>/.
# Stands in for the applicant's separate upload. Uses the AWS CLI container, so no local install needed.
# Usage: .\scripts\upload-samples.ps1            (uploads everything)
#        .\scripts\upload-samples.ps1 -List      (lists the bucket)
param([switch]$List)
$ErrorActionPreference = 'Stop'
$docs = Join-Path (Split-Path $PSScriptRoot -Parent) 'samples\documents'
$aws = @('run','--rm','-e','AWS_ACCESS_KEY_ID=loan','-e','AWS_SECRET_ACCESS_KEY=loan-secret-123','-e','AWS_DEFAULT_REGION=us-east-1')
if ($List) {
    docker @aws amazon/aws-cli --endpoint-url http://host.docker.internal:9000 s3 ls s3://loan-docs/ --recursive
} else {
    docker @aws -v "${docs}:/data:ro" amazon/aws-cli --endpoint-url http://host.docker.internal:9000 s3 sync /data s3://loan-docs/staging/ --delete
}
