# ============================================================================
# MONITOR DE FINDINGS E ALERTAS - FSx COMPLIANCE POC
# ============================================================================
# Este script monitora os findings do Macie e exibe relatórios detalhados
# dos dados sensíveis detectados na solução de compliance
# ============================================================================

param(
    [string]$AWSRegion = "us-east-1",
    [int]$MaxFindings = 50,
    [switch]$ShowDetails,
    [switch]$ExportReport,
    [string]$ReportPath = "C:\ComplianceReports",
    [switch]$Continuous,
    [int]$RefreshInterval = 300  # 5 minutos
)

Write-Host "=== FSx COMPLIANCE POC - MONITOR DE FINDINGS ===" -ForegroundColor Cyan
Write-Host "Monitorando detecções de dados sensíveis do Amazon Macie" -ForegroundColor Yellow
Write-Host ""

# Verificar AWS CLI
try {
    $awsVersion = aws --version 2>$null
    Write-Host "✅ AWS CLI: $($awsVersion.Split()[0])" -ForegroundColor Green
} catch {
    Write-Host "❌ AWS CLI não encontrado" -ForegroundColor Red
    exit 1
}

# Função para obter findings do Macie
function Get-MacieFindings {
    param([int]$MaxResults = 50)
    
    try {
        Write-Host "🔍 Buscando findings do Macie..." -ForegroundColor Yellow
        
        # Listar IDs dos findings
        $findingIds = aws macie2 list-findings --region $AWSRegion --max-items $MaxResults --output json | ConvertFrom-Json
        
        if (!$findingIds.findingIds -or $findingIds.findingIds.Count -eq 0) {
            return @{
                Count = 0
                Findings = @()
                Message = "Nenhum finding encontrado"
            }
        }
        
        Write-Host "📊 Encontrados $($findingIds.findingIds.Count) findings" -ForegroundColor Green
        
        # Obter detalhes dos findings (em lotes de 50)
        $allFindings = @()
        $batchSize = 50
        
        for ($i = 0; $i -lt $findingIds.findingIds.Count; $i += $batchSize) {
            $batch = $findingIds.findingIds[$i..([Math]::Min($i + $batchSize - 1, $findingIds.findingIds.Count - 1))]
            $batchJson = $batch | ConvertTo-Json -Compress
            
            try {
                $findingDetails = aws macie2 get-findings --finding-ids $batchJson --region $AWSRegion --output json | ConvertFrom-Json
                $allFindings += $findingDetails.findings
            } catch {
                Write-Host "⚠️  Erro ao obter detalhes do lote $($i/$batchSize): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        return @{
            Count = $allFindings.Count
            Findings = $allFindings
            Message = "Findings carregados com sucesso"
        }
        
    } catch {
        return @{
            Count = 0
            Findings = @()
            Message = "Erro ao acessar Macie: $($_.Exception.Message)"
        }
    }
}

# Função para formatar findings
function Format-FindingReport {
    param($Findings)
    
    if ($Findings.Count -eq 0) {
        Write-Host "ℹ️  Nenhum finding para exibir" -ForegroundColor Blue
        return
    }
    
    Write-Host ""
    Write-Host "=== RELATÓRIO DE FINDINGS ===" -ForegroundColor Cyan
    Write-Host "Total de findings: $($Findings.Count)" -ForegroundColor White
    Write-Host ""
    
    # Agrupar por severidade
    $severityGroups = $Findings | Group-Object severity
    Write-Host "📊 DISTRIBUIÇÃO POR SEVERIDADE:" -ForegroundColor Yellow
    foreach ($group in $severityGroups) {
        $color = switch ($group.Name) {
            "HIGH" { "Red" }
            "MEDIUM" { "Yellow" }
            "LOW" { "Green" }
            default { "White" }
        }
        Write-Host "   $($group.Name): $($group.Count) findings" -ForegroundColor $color
    }
    
    Write-Host ""
    
    # Agrupar por tipo
    $typeGroups = $Findings | Group-Object type
    Write-Host "🔍 DISTRIBUIÇÃO POR TIPO:" -ForegroundColor Yellow
    foreach ($group in $typeGroups) {
        Write-Host "   $($group.Name): $($group.Count) findings" -ForegroundColor White
    }
    
    Write-Host ""
    
    # Findings mais recentes
    $recentFindings = $Findings | Sort-Object createdAt -Descending | Select-Object -First 10
    Write-Host "🕒 FINDINGS MAIS RECENTES (Top 10):" -ForegroundColor Yellow
    
    foreach ($finding in $recentFindings) {
        $createdAt = [DateTime]::Parse($finding.createdAt).ToString("dd/MM/yyyy HH:mm")
        $severityColor = switch ($finding.severity) {
            "HIGH" { "Red" }
            "MEDIUM" { "Yellow" }
            "LOW" { "Green" }
            default { "White" }
        }
        
        Write-Host ""
        Write-Host "   📄 Finding ID: $($finding.id)" -ForegroundColor Gray
        Write-Host "   📅 Data: $createdAt" -ForegroundColor White
        Write-Host "   ⚠️  Severidade: $($finding.severity)" -ForegroundColor $severityColor
        Write-Host "   🏷️  Tipo: $($finding.type)" -ForegroundColor White
        
        if ($finding.resourcesAffected -and $finding.resourcesAffected.s3Object) {
            $s3Object = $finding.resourcesAffected.s3Object
            Write-Host "   📁 Arquivo: $($s3Object.key)" -ForegroundColor Cyan
            Write-Host "   🪣 Bucket: $($s3Object.bucketName)" -ForegroundColor Cyan
        }
        
        if ($ShowDetails -and $finding.classificationDetails) {
            Write-Host "   🔍 Detalhes da Classificação:" -ForegroundColor Yellow
            
            if ($finding.classificationDetails.result) {
                $result = $finding.classificationDetails.result
                Write-Host "      Status: $($result.status)" -ForegroundColor White
                
                if ($result.customDataIdentifiers) {
                    Write-Host "      Identificadores Customizados:" -ForegroundColor White
                    foreach ($cdi in $result.customDataIdentifiers.detections) {
                        Write-Host "        • $($cdi.name): $($cdi.count) ocorrências" -ForegroundColor Gray
                    }
                }
                
                if ($result.sensitiveData) {
                    Write-Host "      Dados Sensíveis Detectados:" -ForegroundColor White
                    foreach ($category in $result.sensitiveData) {
                        Write-Host "        • Categoria: $($category.category)" -ForegroundColor Gray
                        if ($category.detections) {
                            foreach ($detection in $category.detections) {
                                Write-Host "          - Tipo: $($detection.type)" -ForegroundColor DarkGray
                                Write-Host "          - Ocorrências: $($detection.count)" -ForegroundColor DarkGray
                            }
                        }
                    }
                }
            }
        }
        
        Write-Host "   " + ("-" * 50) -ForegroundColor DarkGray
    }
}

# Função para exportar relatório
function Export-FindingReport {
    param($Findings, $ReportPath)
    
    if (!(Test-Path $ReportPath)) {
        New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportFile = Join-Path $ReportPath "MacieFindings_$timestamp.json"
    $summaryFile = Join-Path $ReportPath "MacieSummary_$timestamp.txt"
    
    # Exportar JSON completo
    $Findings | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportFile -Encoding UTF8
    
    # Criar resumo em texto
    $summary = @"
=== RELATÓRIO DE COMPLIANCE - FSx + Macie ===
Gerado em: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")
Região AWS: $AWSRegion

RESUMO EXECUTIVO:
- Total de Findings: $($Findings.Count)
- Findings de Alta Severidade: $(($Findings | Where-Object {$_.severity -eq "HIGH"}).Count)
- Findings de Média Severidade: $(($Findings | Where-Object {$_.severity -eq "MEDIUM"}).Count)
- Findings de Baixa Severidade: $(($Findings | Where-Object {$_.severity -eq "LOW"}).Count)

TIPOS DE DADOS SENSÍVEIS DETECTADOS:
$($Findings | Group-Object type | ForEach-Object { "- $($_.Name): $($_.Count) ocorrências" } | Out-String)

ARQUIVOS MAIS AFETADOS:
$($Findings | Where-Object {$_.resourcesAffected.s3Object} | 
  Group-Object {$_.resourcesAffected.s3Object.key} | 
  Sort-Object Count -Descending | 
  Select-Object -First 10 | 
  ForEach-Object { "- $($_.Name): $($_.Count) findings" } | Out-String)

RECOMENDAÇÕES:
1. Revisar arquivos com findings de alta severidade
2. Implementar controles de acesso mais restritivos
3. Considerar criptografia adicional para dados sensíveis
4. Treinar usuários sobre políticas de dados sensíveis
5. Implementar monitoramento contínuo

=== FIM DO RELATÓRIO ===
"@
    
    $summary | Out-File -FilePath $summaryFile -Encoding UTF8
    
    Write-Host "📄 Relatório exportado:" -ForegroundColor Green
    Write-Host "   JSON: $reportFile" -ForegroundColor Gray
    Write-Host "   Resumo: $summaryFile" -ForegroundColor Gray
}

# Função para monitoramento contínuo
function Start-ContinuousMonitoring {
    param($RefreshInterval)
    
    Write-Host "🔄 Iniciando monitoramento contínuo..." -ForegroundColor Cyan
    Write-Host "   Intervalo de atualização: $RefreshInterval segundos" -ForegroundColor Gray
    Write-Host "   Pressione Ctrl+C para parar" -ForegroundColor Gray
    Write-Host ""
    
    $lastCount = 0
    
    while ($true) {
        try {
            Clear-Host
            Write-Host "=== MONITORAMENTO CONTÍNUO - $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') ===" -ForegroundColor Cyan
            
            $result = Get-MacieFindings -MaxResults $MaxFindings
            
            if ($result.Count -ne $lastCount) {
                Write-Host "🔔 NOVOS FINDINGS DETECTADOS!" -ForegroundColor Red
                Write-Host "   Anterior: $lastCount | Atual: $($result.Count)" -ForegroundColor Yellow
                $lastCount = $result.Count
            }
            
            Format-FindingReport -Findings $result.Findings
            
            Write-Host ""
            Write-Host "⏰ Próxima atualização em $RefreshInterval segundos..." -ForegroundColor Gray
            Start-Sleep -Seconds $RefreshInterval
            
        } catch {
            Write-Host "❌ Erro no monitoramento: $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 30
        }
    }
}

# Execução principal
try {
    if ($Continuous) {
        Start-ContinuousMonitoring -RefreshInterval $RefreshInterval
    } else {
        $result = Get-MacieFindings -MaxResults $MaxFindings
        
        Write-Host $result.Message -ForegroundColor $(if ($result.Count -gt 0) { "Green" } else { "Blue" })
        
        if ($result.Count -gt 0) {
            Format-FindingReport -Findings $result.Findings
            
            if ($ExportReport) {
                Export-FindingReport -Findings $result.Findings -ReportPath $ReportPath
            }
        }
        
        Write-Host ""
        Write-Host "💡 DICAS:" -ForegroundColor Cyan
        Write-Host "   • Use -ShowDetails para ver detalhes completos" -ForegroundColor White
        Write-Host "   • Use -ExportReport para salvar relatórios" -ForegroundColor White
        Write-Host "   • Use -Continuous para monitoramento em tempo real" -ForegroundColor White
        Write-Host "   • Verifique também o console do Macie: https://console.aws.amazon.com/macie/" -ForegroundColor White
    }
    
} catch {
    Write-Host "❌ Erro na execução: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "✅ Monitoramento concluído!" -ForegroundColor Green
