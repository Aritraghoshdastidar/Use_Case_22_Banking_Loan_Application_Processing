# Runs Maven with the right JDK. Usage (from an app folder):  ..\scripts\mvn.ps1 clean test
# JDK 17 is required: Mule extensions (e.g. Validation) reject Java 21. Studio bundles a Temurin 17.
$jdk17 = 'C:\AnypointStudio\plugins\org.mule.tooling.jdk.win32.x86_64_1.4.1'
$mvn   = 'C:\Users\aritr\tools\apache-maven-3.9.9\bin\mvn.cmd'
if (-not (Test-Path $jdk17)) { Write-Error "JDK 17 not found at $jdk17. Edit scripts\mvn.ps1."; exit 2 }
$env:JAVA_HOME = $jdk17
& $mvn -B @args
exit $LASTEXITCODE
