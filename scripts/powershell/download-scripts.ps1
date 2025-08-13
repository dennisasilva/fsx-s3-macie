# ============================================================================
# DOWNLOAD AUTOMÁTICO DOS SCRIPTS DE COMPLIANCE
# ============================================================================
# Execute este script na instância Windows para baixar todos os scripts
# ============================================================================

param(
    [string]$TargetPath = "C:\ComplianceTest",
    [string]$S3Bucket = "",
    [switch]$UseLocalFiles
)

Write-Host "=== DOWNLOAD DOS SCRIPTS DE COMPLIANCE ===" -ForegroundColor Cyan
Write-Host "Baixando scripts para teste de compliance..." -ForegroundColor Yellow
Write-Host ""

# Criar diretório de destino
if (!(Test-Path $TargetPath)) {
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    Write-Host "✅ Diretório criado: $TargetPath" -ForegroundColor Green
}

Set-Location $TargetPath

# Definir conteúdo dos scripts inline (para não depender de download externo)
$scripts = @{
    "quick-compliance-test.ps1" = @'
# QUICK COMPLIANCE TEST - FSx + Macie PoC
param(
    [int]$NumTestFiles = 3,
    [string]$FSxDrive = "Z",
    [switch]$SkipGeneration,
    [switch]$MonitorOnly
)

Write-Host "=== QUICK COMPLIANCE TEST - FSx + Macie PoC ===" -ForegroundColor Cyan
Write-Host "Teste rápido da solução de compliance com dados fictícios" -ForegroundColor Yellow
Write-Host ""

# Verificar AWS CLI
try {
    $awsVersion = aws --version 2>$null
    Write-Host "✅ AWS CLI: $($awsVersion.Split()[0])" -ForegroundColor Green
} catch {
    Write-Host "❌ AWS CLI não encontrado. Instale primeiro." -ForegroundColor Red
    exit 1
}

# Verificar FSx
$fsxPath = "${FSxDrive}:\"
if (!(Test-Path $fsxPath)) {
    Write-Host "❌ FSx não montado em $fsxPath" -ForegroundColor Red
    exit 1
}
Write-Host "✅ FSx montado: $fsxPath" -ForegroundColor Green

if ($MonitorOnly) {
    Write-Host ""
    Write-Host "=== VERIFICANDO FINDINGS ===" -ForegroundColor Cyan
    
    try {
        $findings = aws macie2 list-findings --region us-east-1 --output json | ConvertFrom-Json
        if ($findings.findingIds -and $findings.findingIds.Count -gt 0) {
            Write-Host "🎉 FINDINGS ENCONTRADOS: $($findings.findingIds.Count)" -ForegroundColor Green
            
            $firstFew = $findings.findingIds | Select-Object -First 5
            $details = aws macie2 get-findings --finding-ids ($firstFew | ConvertTo-Json -Compress) --region us-east-1 --output json | ConvertFrom-Json
            
            foreach ($finding in $details.findings) {
                $createdAt = [DateTime]::Parse($finding.createdAt).ToString("dd/MM/yyyy HH:mm")
                Write-Host ""
                Write-Host "   🔍 Tipo: $($finding.type)" -ForegroundColor White
                Write-Host "   📅 Data: $createdAt" -ForegroundColor Gray
                Write-Host "   ⚠️  Severidade: $($finding.severity)" -ForegroundColor $(
                    switch ($finding.severity) {
                        "HIGH" { "Red" }
                        "MEDIUM" { "Yellow" }
                        "LOW" { "Green" }
                        default { "White" }
                    }
                )
                if ($finding.resourcesAffected.s3Object) {
                    Write-Host "   📄 Arquivo: $($finding.resourcesAffected.s3Object.key)" -ForegroundColor Cyan
                }
            }
        } else {
            Write-Host "ℹ️  Nenhum finding encontrado ainda" -ForegroundColor Blue
        }
    } catch {
        Write-Host "⚠️  Erro ao verificar findings: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    exit 0
}

# Gerar dados de teste
if (!$SkipGeneration) {
    Write-Host ""
    Write-Host "=== GERANDO DADOS DE TESTE ===" -ForegroundColor Cyan
    
    $testDataPath = "C:\FSxTestData"
    if (!(Test-Path $testDataPath)) {
        New-Item -ItemType Directory -Path $testDataPath -Force | Out-Null
    }
    
    Write-Host "Gerando $NumTestFiles arquivos com dados sensíveis fictícios..." -ForegroundColor Yellow
    
    for ($i = 1; $i -le $NumTestFiles; $i++) {
        $fileName = "TestDocument_$i" + "_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $filePath = Join-Path $testDataPath $fileName
        
        $content = @"
DOCUMENTO DE TESTE - CONFIDENCIAL
=================================
Data: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")
Documento #$i de $NumTestFiles

⚠️  ATENÇÃO: DADOS FICTÍCIOS PARA TESTE ⚠️

DADOS SENSÍVEIS INCLUÍDOS:
- CPF: 123.456.789-0$i
- Senha: teste_senha_$i
- Cartão: 4532-1234-5678-901$i
- Email: usuario$i@empresa.com

INFORMAÇÕES CONFIDENCIAIS:
Este documento contém DADOS PESSOAIS fictícios.
Classificação: RESTRITO
Acesso: SIGILOSO

PASSWORD do sistema: admin123_$i
Dados CLASSIFIED para teste de compliance.

=== FIM DO DOCUMENTO ===
"@
        
        $content | Out-File -FilePath $filePath -Encoding UTF8
        Write-Host "✅ Criado: $fileName" -ForegroundColor Green
    }
    
    # Copiar para FSx
    Write-Host ""
    Write-Host "=== COPIANDO PARA FSx ===" -ForegroundColor Cyan
    
    $fsxSyncPath = "${FSxDrive}:\fsx-sync"
    if (!(Test-Path $fsxSyncPath)) {
        New-Item -ItemType Directory -Path $fsxSyncPath -Force | Out-Null
    }
    
    Copy-Item "$testDataPath\*" -Destination $fsxSyncPath -Force
    $copiedFiles = Get-ChildItem $fsxSyncPath -File -Filter "TestDocument_*"
    Write-Host "✅ $($copiedFiles.Count) arquivos copiados para FSx" -ForegroundColor Green
}

Write-Host ""
Write-Host "✅ TESTE CONFIGURADO COM SUCESSO!" -ForegroundColor Green
Write-Host "Execute com -MonitorOnly para verificar findings" -ForegroundColor White
'@

    "generate-test-data.ps1" = @'
# GERADOR DE DADOS DE TESTE PARA FSx COMPLIANCE POC
param(
    [string]$TestDataPath = "C:\FSxTestData",
    [int]$NumFiles = 5,
    [switch]$Verbose
)

Write-Host "=== GERADOR DE DADOS DE TESTE ===" -ForegroundColor Cyan

if (!(Test-Path $TestDataPath)) {
    New-Item -ItemType Directory -Path $TestDataPath -Force | Out-Null
    Write-Host "✅ Diretório criado: $TestDataPath" -ForegroundColor Green
}

$templates = @(
    "Relatório Financeiro - CONFIDENCIAL",
    "Contrato de Funcionário - SIGILOSO", 
    "Política de Segurança - CLASSIFIED",
    "Lista de Clientes - RESTRITO",
    "Backup de Senhas - ULTRA CONFIDENCIAL"
)

for ($i = 1; $i -le $NumFiles; $i++) {
    $template = $templates | Get-Random
    $fileName = "TestDocument_$i" + "_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $filePath = Join-Path $TestDataPath $fileName
    
    $content = @"
$template
=================================
Data: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")

DADOS SENSÍVEIS FICTÍCIOS:
- CPF: $(Get-Random -Minimum 100 -Maximum 999).$(Get-Random -Minimum 100 -Maximum 999).$(Get-Random -Minimum 100 -Maximum 999)-$(Get-Random -Minimum 10 -Maximum 99)
- Senha: senha_teste_$i
- Cartão: 4532-$(Get-Random -Minimum 1000 -Maximum 9999)-$(Get-Random -Minimum 1000 -Maximum 9999)-$(Get-Random -Minimum 1000 -Maximum 9999)
- SSN: $(Get-Random -Minimum 100 -Maximum 999)-$(Get-Random -Minimum 10 -Maximum 99)-$(Get-Random -Minimum 1000 -Maximum 9999)

CLASSIFICAÇÃO: CONFIDENCIAL
DADOS PESSOAIS incluídos para teste
PASSWORD: admin_$i
Informações RESTRITAS e SIGILOSAS

Este documento é CLASSIFIED para demonstração.
"@
    
    $content | Out-File -FilePath $filePath -Encoding UTF8
    Write-Host "✅ Criado: $fileName" -ForegroundColor Green
}

Write-Host "✅ $NumFiles arquivos gerados em $TestDataPath" -ForegroundColor Green
'@
}

Write-Host "📥 Criando scripts localmente..." -ForegroundColor Yellow

foreach ($scriptName in $scripts.Keys) {
    try {
        $scripts[$scriptName] | Out-File -FilePath $scriptName -Encoding UTF8
        Write-Host "✅ Criado: $scriptName" -ForegroundColor Green
    } catch {
        Write-Host "❌ Erro ao criar $scriptName" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "✅ SCRIPTS BAIXADOS COM SUCESSO!" -ForegroundColor Green
Write-Host ""
Write-Host "📋 SCRIPTS DISPONÍVEIS:" -ForegroundColor Cyan
Get-ChildItem *.ps1 | ForEach-Object {
    Write-Host "   • $($_.Name)" -ForegroundColor White
}

Write-Host ""
Write-Host "🚀 COMO USAR:" -ForegroundColor Cyan
Write-Host "   # Teste rápido completo" -ForegroundColor Gray
Write-Host "   .\quick-compliance-test.ps1 -NumTestFiles 3" -ForegroundColor White
Write-Host ""
Write-Host "   # Apenas gerar dados" -ForegroundColor Gray
Write-Host "   .\generate-test-data.ps1 -NumFiles 5" -ForegroundColor White
Write-Host ""
Write-Host "   # Monitorar findings" -ForegroundColor Gray
Write-Host "   .\quick-compliance-test.ps1 -MonitorOnly" -ForegroundColor White

Write-Host ""
Write-Host "⚠️  IMPORTANTE:" -ForegroundColor Red
Write-Host "   Todos os dados são FICTÍCIOS para teste apenas!" -ForegroundColor White
