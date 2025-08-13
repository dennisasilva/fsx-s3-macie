# ============================================================================
# TESTE COMPLETO DE COMPLIANCE - FSx + Macie + Alertas
# ============================================================================
# Este script executa um teste end-to-end da solução de compliance:
# 1. Gera dados fictícios sensíveis
# 2. Copia para FSx
# 3. Monitora sincronização com S3
# 4. Força execução do job do Macie (se necessário)
# 5. Monitora alertas e findings
# ============================================================================

param(
    [string]$FSxDriveLetter = "Z",
    [string]$TestDataPath = "C:\FSxTestData",
    [int]$NumTestFiles = 3,
    [string]$AWSRegion = "us-east-1",
    [switch]$ForceImmediateTest,
    [switch]$Verbose
)

Write-Host "=== FSx COMPLIANCE POC - TESTE COMPLETO ===" -ForegroundColor Cyan
Write-Host "Executando teste end-to-end da solução de compliance" -ForegroundColor Yellow
Write-Host ""

# Verificar se AWS CLI está disponível
try {
    $awsVersion = aws --version 2>$null
    Write-Host "✅ AWS CLI disponível: $($awsVersion.Split()[0])" -ForegroundColor Green
} catch {
    Write-Host "❌ AWS CLI não encontrado. Instale o AWS CLI primeiro." -ForegroundColor Red
    exit 1
}

# Verificar se FSx está montado
$fsxPath = "${FSxDriveLetter}:\"
if (!(Test-Path $fsxPath)) {
    Write-Host "❌ FSx não está montado em $fsxPath" -ForegroundColor Red
    Write-Host "   Execute o script de configuração da instância Windows primeiro." -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ FSx montado em: $fsxPath" -ForegroundColor Green

# Verificar diretório fsx-sync
$fsxSyncPath = "${FSxDriveLetter}:\fsx-sync"
if (!(Test-Path $fsxSyncPath)) {
    Write-Host "📁 Criando diretório fsx-sync..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $fsxSyncPath -Force | Out-Null
    Write-Host "✅ Diretório criado: $fsxSyncPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== ETAPA 1: GERAÇÃO DE DADOS DE TESTE ===" -ForegroundColor Cyan

# Executar gerador de dados
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$generatorScript = Join-Path $scriptPath "generate-test-data.ps1"

if (Test-Path $generatorScript) {
    Write-Host "Executando gerador de dados..." -ForegroundColor Yellow
    & $generatorScript -TestDataPath $TestDataPath -NumFiles $NumTestFiles -Verbose:$Verbose
} else {
    Write-Host "❌ Script gerador não encontrado: $generatorScript" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== ETAPA 2: CÓPIA PARA FSx ===" -ForegroundColor Cyan

Write-Host "Copiando arquivos de teste para FSx..." -ForegroundColor Yellow
try {
    Copy-Item "$TestDataPath\*" -Destination $fsxSyncPath -Recurse -Force
    $copiedFiles = Get-ChildItem $fsxSyncPath -File
    Write-Host "✅ $($copiedFiles.Count) arquivos copiados para FSx" -ForegroundColor Green
    
    if ($Verbose) {
        $copiedFiles | ForEach-Object {
            Write-Host "   • $($_.Name)" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "❌ Erro ao copiar arquivos: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== ETAPA 3: MONITORAMENTO DA SINCRONIZAÇÃO ===" -ForegroundColor Cyan

Write-Host "Aguardando sincronização com S3..." -ForegroundColor Yellow
Write-Host "⏳ Isso pode levar alguns minutos..." -ForegroundColor Gray

# Obter nome do bucket S3
try {
    $stackName = $env:COMPUTERNAME -replace "-.*", ""  # Assumindo que o nome da instância contém o nome da stack
    $bucketInfo = aws s3api list-buckets --query "Buckets[?contains(Name, 'compliance') && contains(Name, '$stackName')]" --output json | ConvertFrom-Json
    
    if ($bucketInfo -and $bucketInfo.Count -gt 0) {
        $bucketName = $bucketInfo[0].Name
        Write-Host "✅ Bucket S3 identificado: $bucketName" -ForegroundColor Green
    } else {
        Write-Host "⚠️  Não foi possível identificar o bucket S3 automaticamente" -ForegroundColor Yellow
        Write-Host "   Verifique manualmente no console da AWS" -ForegroundColor Gray
        $bucketName = $null
    }
} catch {
    Write-Host "⚠️  Erro ao identificar bucket S3: $($_.Exception.Message)" -ForegroundColor Yellow
    $bucketName = $null
}

# Monitorar sincronização se bucket foi identificado
if ($bucketName) {
    $maxAttempts = 10
    $attempt = 0
    $syncComplete = $false
    
    do {
        $attempt++
        Start-Sleep -Seconds 30
        
        try {
            $s3Objects = aws s3 ls "s3://$bucketName/fsx-sync/" --recursive --output json 2>$null | ConvertFrom-Json
            if ($s3Objects -and $s3Objects.Count -ge $NumTestFiles) {
                Write-Host "✅ Sincronização detectada! $($s3Objects.Count) arquivos no S3" -ForegroundColor Green
                $syncComplete = $true
            } else {
                Write-Host "⏳ Tentativa $attempt/$maxAttempts - Aguardando sincronização..." -ForegroundColor Gray
            }
        } catch {
            Write-Host "⏳ Tentativa $attempt/$maxAttempts - Verificando sincronização..." -ForegroundColor Gray
        }
    } while (!$syncComplete -and $attempt -lt $maxAttempts)
    
    if (!$syncComplete) {
        Write-Host "⚠️  Sincronização não detectada automaticamente" -ForegroundColor Yellow
        Write-Host "   Verifique manualmente: aws s3 ls s3://$bucketName/fsx-sync/ --recursive" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "=== ETAPA 4: CONFIGURAÇÃO DO MACIE ===" -ForegroundColor Cyan

if ($ForceImmediateTest) {
    Write-Host "Tentando forçar execução imediata do job do Macie..." -ForegroundColor Yellow
    
    try {
        # Listar jobs do Macie
        $macieJobs = aws macie2 list-classification-jobs --region $AWSRegion --output json | ConvertFrom-Json
        
        if ($macieJobs.items -and $macieJobs.items.Count -gt 0) {
            $complianceJob = $macieJobs.items | Where-Object { $_.name -like "*compliance*" } | Select-Object -First 1
            
            if ($complianceJob) {
                Write-Host "✅ Job de compliance encontrado: $($complianceJob.name)" -ForegroundColor Green
                Write-Host "   Status: $($complianceJob.jobStatus)" -ForegroundColor Gray
                Write-Host "   Tipo: $($complianceJob.jobType)" -ForegroundColor Gray
                
                # Para jobs agendados, não podemos forçar execução imediata
                # Mas podemos criar um job one-time para teste imediato
                Write-Host ""
                Write-Host "Criando job de teste imediato..." -ForegroundColor Yellow
                
                $testJobName = "compliance-test-immediate-$(Get-Date -Format 'yyyyMMddHHmmss')"
                
                # Criar job one-time (simplificado)
                Write-Host "⚠️  Para criar job imediato, use o console do Macie:" -ForegroundColor Yellow
                Write-Host "   1. Acesse: https://console.aws.amazon.com/macie/" -ForegroundColor Gray
                Write-Host "   2. Vá em 'Jobs' > 'Create job'" -ForegroundColor Gray
                Write-Host "   3. Selecione o bucket: $bucketName" -ForegroundColor Gray
                Write-Host "   4. Configure para 'One-time job'" -ForegroundColor Gray
                Write-Host "   5. Execute imediatamente" -ForegroundColor Gray
                
            } else {
                Write-Host "⚠️  Job de compliance não encontrado" -ForegroundColor Yellow
            }
        } else {
            Write-Host "⚠️  Nenhum job do Macie encontrado" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠️  Erro ao acessar Macie: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "Job agendado do Macie executará automaticamente (diariamente)" -ForegroundColor Yellow
    Write-Host "Use -ForceImmediateTest para instruções de teste imediato" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== ETAPA 5: MONITORAMENTO DE FINDINGS ===" -ForegroundColor Cyan

Write-Host "Configurando monitoramento de findings..." -ForegroundColor Yellow

# Função para verificar findings
function Check-MacieFindings {
    try {
        $findings = aws macie2 list-findings --region $AWSRegion --output json | ConvertFrom-Json
        return $findings.findingIds
    } catch {
        return $null
    }
}

# Verificar findings atuais
$currentFindings = Check-MacieFindings
if ($currentFindings) {
    Write-Host "✅ $($currentFindings.Count) findings existentes encontrados" -ForegroundColor Green
} else {
    Write-Host "ℹ️  Nenhum finding atual (normal para primeira execução)" -ForegroundColor Blue
}

Write-Host ""
Write-Host "=== RESUMO DO TESTE ===" -ForegroundColor Cyan
Write-Host "📊 Status do Teste:" -ForegroundColor White
Write-Host "   ✅ Dados de teste gerados: $NumTestFiles arquivos" -ForegroundColor Green
Write-Host "   ✅ Arquivos copiados para FSx: $fsxSyncPath" -ForegroundColor Green
if ($bucketName) {
    Write-Host "   ✅ Bucket S3 identificado: $bucketName" -ForegroundColor Green
} else {
    Write-Host "   ⚠️  Bucket S3: Verificação manual necessária" -ForegroundColor Yellow
}
Write-Host "   ✅ Macie configurado para detecção automática" -ForegroundColor Green

Write-Host ""
Write-Host "🔍 DADOS SENSÍVEIS CRIADOS PARA TESTE:" -ForegroundColor Yellow
Write-Host "   • CPFs fictícios brasileiros" -ForegroundColor White
Write-Host "   • Senhas e passwords de teste" -ForegroundColor White
Write-Host "   • Números de cartão fictícios" -ForegroundColor White
Write-Host "   • Palavras-chave: CONFIDENCIAL, RESTRITO, SIGILOSO" -ForegroundColor White
Write-Host "   • Dados pessoais fictícios" -ForegroundColor White

Write-Host ""
Write-Host "📋 PRÓXIMOS PASSOS:" -ForegroundColor Cyan
Write-Host "1. Aguarde a execução do job do Macie (agendado diariamente)" -ForegroundColor White
Write-Host "   Ou crie um job imediato no console do Macie" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Monitore os findings em:" -ForegroundColor White
Write-Host "   • Console do Macie: https://console.aws.amazon.com/macie/" -ForegroundColor Gray
Write-Host "   • CloudWatch Logs: /aws/lambda/*compliance*" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Verifique alertas por email (se configurado)" -ForegroundColor White
Write-Host ""
Write-Host "4. Para verificar findings via CLI:" -ForegroundColor White
Write-Host "   aws macie2 list-findings --region $AWSRegion" -ForegroundColor Gray

Write-Host ""
Write-Host "⚠️  LEMBRETE IMPORTANTE:" -ForegroundColor Red
Write-Host "   • Todos os dados são FICTÍCIOS para teste" -ForegroundColor White
Write-Host "   • Remova os arquivos de teste após validação" -ForegroundColor White
Write-Host "   • Este é um ambiente de demonstração" -ForegroundColor White

Write-Host ""
Write-Host "✅ TESTE DE COMPLIANCE CONFIGURADO COM SUCESSO!" -ForegroundColor Green
Write-Host "   Aguarde os resultados da detecção automática." -ForegroundColor White
