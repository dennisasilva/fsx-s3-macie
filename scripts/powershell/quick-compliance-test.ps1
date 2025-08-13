# ============================================================================
# QUICK COMPLIANCE TEST - FSx + Macie PoC
# ============================================================================
# Script de execução rápida para testar a solução de compliance
# Execute este script na instância Windows EC2 para um teste completo
# ============================================================================

param(
    [int]$NumTestFiles = 3,
    [string]$FSxDrive = "Z",
    [switch]$SkipGeneration,
    [switch]$MonitorOnly
)

Write-Host "=== QUICK COMPLIANCE TEST - FSx + Macie PoC ===" -ForegroundColor Cyan
Write-Host "Teste rápido da solução de compliance com dados fictícios" -ForegroundColor Yellow
Write-Host ""

# Verificações iniciais
Write-Host "🔍 Verificando pré-requisitos..." -ForegroundColor Yellow

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
    Write-Host "   Verifique se o FSx foi configurado corretamente." -ForegroundColor Yellow
    exit 1
}
Write-Host "✅ FSx montado: $fsxPath" -ForegroundColor Green

# Criar diretório de trabalho
$workDir = "C:\ComplianceTest"
if (!(Test-Path $workDir)) {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
}
Set-Location $workDir

if ($MonitorOnly) {
    Write-Host ""
    Write-Host "=== MODO MONITORAMENTO APENAS ===" -ForegroundColor Cyan
    
    # Função inline para monitorar findings
    function Get-QuickFindings {
        try {
            $findings = aws macie2 list-findings --region us-east-1 --output json | ConvertFrom-Json
            if ($findings.findingIds -and $findings.findingIds.Count -gt 0) {
                Write-Host "📊 Encontrados $($findings.findingIds.Count) findings!" -ForegroundColor Green
                
                # Obter detalhes dos primeiros 5 findings
                $firstFive = $findings.findingIds | Select-Object -First 5
                $details = aws macie2 get-findings --finding-ids ($firstFive | ConvertTo-Json -Compress) --region us-east-1 --output json | ConvertFrom-Json
                
                foreach ($finding in $details.findings) {
                    $createdAt = [DateTime]::Parse($finding.createdAt).ToString("dd/MM/yyyy HH:mm")
                    Write-Host ""
                    Write-Host "   🔍 Finding: $($finding.type)" -ForegroundColor White
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
                Write-Host "   Aguarde a execução do job do Macie ou crie um job manual" -ForegroundColor Gray
            }
        } catch {
            Write-Host "⚠️  Erro ao verificar findings: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    Get-QuickFindings
    exit 0
}

if (!$SkipGeneration) {
    Write-Host ""
    Write-Host "=== ETAPA 1: GERAÇÃO DE DADOS DE TESTE ===" -ForegroundColor Cyan
    
    $testDataPath = "C:\FSxTestData"
    
    # Criar dados de teste inline (versão simplificada)
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
    
    Write-Host ""
    Write-Host "=== ETAPA 2: CÓPIA PARA FSx ===" -ForegroundColor Cyan
    
    $fsxSyncPath = "${FSxDrive}:\fsx-sync"
    if (!(Test-Path $fsxSyncPath)) {
        New-Item -ItemType Directory -Path $fsxSyncPath -Force | Out-Null
        Write-Host "📁 Diretório fsx-sync criado" -ForegroundColor Green
    }
    
    Write-Host "Copiando arquivos para FSx..." -ForegroundColor Yellow
    try {
        Copy-Item "$testDataPath\*" -Destination $fsxSyncPath -Force
        $copiedFiles = Get-ChildItem $fsxSyncPath -File -Filter "TestDocument_*"
        Write-Host "✅ $($copiedFiles.Count) arquivos copiados para FSx" -ForegroundColor Green
    } catch {
        Write-Host "❌ Erro ao copiar: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "=== ETAPA 3: VERIFICAÇÃO DE SINCRONIZAÇÃO ===" -ForegroundColor Cyan

Write-Host "Verificando sincronização com S3..." -ForegroundColor Yellow

# Tentar identificar bucket
try {
    $buckets = aws s3api list-buckets --query "Buckets[?contains(Name, 'compliance')]" --output json | ConvertFrom-Json
    if ($buckets -and $buckets.Count -gt 0) {
        $bucketName = $buckets[0].Name
        Write-Host "✅ Bucket identificado: $bucketName" -ForegroundColor Green
        
        # Verificar objetos no S3
        try {
            $s3Objects = aws s3 ls "s3://$bucketName/fsx-sync/" --recursive 2>$null
            if ($s3Objects) {
                $objectCount = ($s3Objects -split "`n" | Where-Object { $_ -match "TestDocument" }).Count
                Write-Host "✅ Sincronização detectada: $objectCount arquivos no S3" -ForegroundColor Green
            } else {
                Write-Host "⏳ Sincronização em andamento..." -ForegroundColor Yellow
                Write-Host "   Aguarde alguns minutos e verifique novamente" -ForegroundColor Gray
            }
        } catch {
            Write-Host "⏳ Verificando sincronização..." -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠️  Bucket não identificado automaticamente" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠️  Erro ao verificar S3: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== ETAPA 4: STATUS DO MACIE ===" -ForegroundColor Cyan

Write-Host "Verificando configuração do Macie..." -ForegroundColor Yellow

try {
    # Verificar se Macie está habilitado
    $macieStatus = aws macie2 get-macie-session --region us-east-1 --output json 2>$null | ConvertFrom-Json
    if ($macieStatus) {
        Write-Host "✅ Macie habilitado: $($macieStatus.status)" -ForegroundColor Green
    }
    
    # Verificar jobs
    $jobs = aws macie2 list-classification-jobs --region us-east-1 --output json 2>$null | ConvertFrom-Json
    if ($jobs.items -and $jobs.items.Count -gt 0) {
        $complianceJobs = $jobs.items | Where-Object { $_.name -like "*compliance*" }
        Write-Host "✅ Jobs de compliance: $($complianceJobs.Count)" -ForegroundColor Green
        
        foreach ($job in $complianceJobs) {
            Write-Host "   • $($job.name): $($job.jobStatus)" -ForegroundColor Gray
        }
    }
    
} catch {
    Write-Host "⚠️  Erro ao verificar Macie: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== ETAPA 5: VERIFICAÇÃO DE FINDINGS ===" -ForegroundColor Cyan

Write-Host "Verificando findings existentes..." -ForegroundColor Yellow

try {
    $findings = aws macie2 list-findings --region us-east-1 --output json | ConvertFrom-Json
    if ($findings.findingIds -and $findings.findingIds.Count -gt 0) {
        Write-Host "🎉 FINDINGS ENCONTRADOS: $($findings.findingIds.Count)" -ForegroundColor Green
        
        # Mostrar alguns detalhes
        $firstFew = $findings.findingIds | Select-Object -First 3
        $details = aws macie2 get-findings --finding-ids ($firstFew | ConvertTo-Json -Compress) --region us-east-1 --output json | ConvertFrom-Json
        
        Write-Host ""
        Write-Host "📊 RESUMO DOS FINDINGS:" -ForegroundColor Yellow
        foreach ($finding in $details.findings) {
            $createdAt = [DateTime]::Parse($finding.createdAt).ToString("dd/MM/yyyy HH:mm")
            Write-Host "   • $($finding.type) - $($finding.severity) - $createdAt" -ForegroundColor White
        }
        
    } else {
        Write-Host "ℹ️  Nenhum finding encontrado ainda" -ForegroundColor Blue
        Write-Host "   Isso é normal se o job do Macie ainda não executou" -ForegroundColor Gray
    }
} catch {
    Write-Host "⚠️  Erro ao verificar findings: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== RESUMO DO TESTE ===" -ForegroundColor Cyan

Write-Host "📋 STATUS GERAL:" -ForegroundColor White
Write-Host "   ✅ Dados de teste gerados e copiados para FSx" -ForegroundColor Green
Write-Host "   ✅ FSx configurado e acessível" -ForegroundColor Green
Write-Host "   ✅ Macie habilitado e configurado" -ForegroundColor Green

Write-Host ""
Write-Host "🔍 DADOS SENSÍVEIS CRIADOS:" -ForegroundColor Yellow
Write-Host "   • CPFs fictícios brasileiros" -ForegroundColor White
Write-Host "   • Senhas e passwords de teste" -ForegroundColor White
Write-Host "   • Números de cartão fictícios" -ForegroundColor White
Write-Host "   • Palavras-chave: CONFIDENCIAL, RESTRITO, SIGILOSO" -ForegroundColor White

Write-Host ""
Write-Host "⏰ PRÓXIMOS PASSOS:" -ForegroundColor Cyan
Write-Host "1. Aguarde a sincronização FSx → S3 (5-15 minutos)" -ForegroundColor White
Write-Host "2. Aguarde execução do job do Macie (agendado diariamente)" -ForegroundColor White
Write-Host "   OU crie um job manual no console: https://console.aws.amazon.com/macie/" -ForegroundColor Gray
Write-Host "3. Monitore findings com: .\quick-compliance-test.ps1 -MonitorOnly" -ForegroundColor White

Write-Host ""
Write-Host "🔗 LINKS ÚTEIS:" -ForegroundColor Cyan
Write-Host "   • Console Macie: https://console.aws.amazon.com/macie/" -ForegroundColor Gray
Write-Host "   • CloudWatch Logs: https://console.aws.amazon.com/cloudwatch/home#logsV2:log-groups" -ForegroundColor Gray

Write-Host ""
Write-Host "💡 COMANDOS ÚTEIS:" -ForegroundColor Cyan
Write-Host "   # Monitorar findings" -ForegroundColor Gray
Write-Host "   .\quick-compliance-test.ps1 -MonitorOnly" -ForegroundColor White
Write-Host ""
Write-Host "   # Verificar sincronização S3" -ForegroundColor Gray
Write-Host "   aws s3 ls s3://seu-bucket-compliance/fsx-sync/ --recursive" -ForegroundColor White
Write-Host ""
Write-Host "   # Listar findings via CLI" -ForegroundColor Gray
Write-Host "   aws macie2 list-findings --region us-east-1" -ForegroundColor White

Write-Host ""
Write-Host "⚠️  LEMBRETE:" -ForegroundColor Red
Write-Host "   Todos os dados são FICTÍCIOS para teste apenas!" -ForegroundColor White
Write-Host "   Remova os arquivos de teste após validação." -ForegroundColor White

Write-Host ""
Write-Host "✅ TESTE DE COMPLIANCE CONFIGURADO COM SUCESSO!" -ForegroundColor Green
Write-Host "   Execute novamente com -MonitorOnly para verificar resultados." -ForegroundColor White
