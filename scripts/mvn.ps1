# Runs Maven with a JDK 17. Usage (from an app folder):  ..\scripts\mvn.ps1 clean test
# JDK 17 is required: Mule extensions (e.g. Validation) reject Java 21 and 25.
# JDK is taken from the first of: $env:JDK17_HOME, the JDK bundled with Anypoint Studio, the JDK installed by Anypoint Code Builder, a Temurin 17 under Program Files.
# Maven is taken from the first of: $env:MAVEN_HOME, %USERPROFILE%\tools\apache-maven-3.9.9, mvn on the PATH.
$jdkCandidates = @(
    $env:JDK17_HOME,
    'C:\AnypointStudio\plugins\org.mule.tooling.jdk.win32.x86_64_1.4.1',
    (Get-ChildItem (Join-Path $env:USERPROFILE 'AnypointCodeBuilder\java\jdk-17*') -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
    (Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium\jdk-17*" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
)
$jdk17 = $jdkCandidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\java.exe')) } | Select-Object -First 1
if (-not $jdk17) { Write-Error 'JDK 17 not found. Install Temurin 17 or set JDK17_HOME to its folder.'; exit 2 }
$mvnCandidates = @(
    $(if ($env:MAVEN_HOME) { Join-Path $env:MAVEN_HOME 'bin\mvn.cmd' }),
    (Join-Path $env:USERPROFILE 'tools\apache-maven-3.9.9\bin\mvn.cmd'),
    (Get-Command mvn.cmd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
)
$mvn = $mvnCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $mvn) { Write-Error 'Maven 3.9 not found. Install it or set MAVEN_HOME.'; exit 2 }
$env:JAVA_HOME = $jdk17
& $mvn -B @args
exit $LASTEXITCODE
