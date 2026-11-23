param(
    [string]$ApiBaseUrl = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LocalPropertiesPath = Join-Path $Root "android\local.properties"
$env:Path = "C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\dev\tools\flutter\bin;C:\dev\tools\flutter\bin\mingit\cmd;$env:Path"

if (-not (Test-Path $LocalPropertiesPath)) {
    throw "android\local.properties 파일이 없습니다. kakao.native.app.key=네이티브앱키 를 먼저 추가해 주세요."
}

$Properties = @{}
foreach ($RawLine in Get-Content $LocalPropertiesPath) {
    $Line = $RawLine.Trim()
    if ($Line.Length -eq 0 -or $Line.StartsWith("#")) {
        continue
    }
    $Match = [regex]::Match($Line, "^([^=]+)=(.*)$")
    if ($Match.Success) {
        $Properties[$Match.Groups[1].Value.Trim()] = $Match.Groups[2].Value.Trim()
    }
}

$KakaoNativeAppKey = $Properties["kakao.native.app.key"]
if ([string]::IsNullOrWhiteSpace($KakaoNativeAppKey)) {
    throw "android\local.properties에 kakao.native.app.key 값이 비어 있습니다."
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl = $Properties["api.base.url"]
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    throw "api.base.url 또는 -ApiBaseUrl을 설정해 주세요."
}

$FlutterArgs = @(
    "build",
    "apk",
    "--release",
    "--dart-define=KAKAO_NATIVE_APP_KEY=$KakaoNativeAppKey"
)

if (-not [string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $FlutterArgs += "--dart-define=API_BASE_URL=$ApiBaseUrl"
}

$FlutterCommand = $env:FLUTTER_BIN
if ([string]::IsNullOrWhiteSpace($FlutterCommand)) {
    $BundledFlutter = "C:\dev\tools\flutter\bin\flutter.bat"
    if (Test-Path $BundledFlutter) {
        $FlutterCommand = $BundledFlutter
    }
    else {
        $FlutterCommand = "flutter"
    }
}

Push-Location $Root
try {
    if ($FlutterCommand.EndsWith(".bat", [System.StringComparison]::OrdinalIgnoreCase)) {
        $EscapedArgs = $FlutterArgs | ForEach-Object {
            if ($_ -match '[\s&()"]') {
                '"' + ($_ -replace '"', '\"') + '"'
            }
            else {
                $_
            }
        }
        $CommandLine = '"' + $FlutterCommand + '" ' + ($EscapedArgs -join " ")
        & "C:\Windows\System32\cmd.exe" /d /c $CommandLine
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    else {
        & $FlutterCommand @FlutterArgs
    }
}
finally {
    Pop-Location
}
