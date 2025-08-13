# ============================================================================
# GERADOR DE DADOS DE TESTE PARA FSx COMPLIANCE POC
# ============================================================================
# Este script cria arquivos com dados fictícios sensíveis para testar
# a detecção automática do Amazon Macie e gerar alertas de compliance
# ============================================================================

param(
    [string]$TestDataPath = "C:\FSxTestData",
    [int]$NumFiles = 5,
    [switch]$Verbose
)

Write-Host "=== FSx Compliance PoC - Gerador de Dados de Teste ===" -ForegroundColor Cyan
Write-Host "Criando arquivos com dados fictícios sensíveis..." -ForegroundColor Yellow
Write-Host ""

# Criar diretório de teste se não existir
if (!(Test-Path $TestDataPath)) {
    New-Item -ItemType Directory -Path $TestDataPath -Force | Out-Null
    Write-Host "✅ Diretório criado: $TestDataPath" -ForegroundColor Green
}

# Dados fictícios sensíveis para teste
$sensitiveData = @{
    "CPF" = @(
        "123.456.789-01",
        "987.654.321-00", 
        "111.222.333-44",
        "555.666.777-88"
    )
    "Senhas" = @(
        "senha: admin123",
        "password: secreto456",
        "SENHA: minhasenha789",
        "PASSWORD: confidencial2024"
    )
    "CartaoCredito" = @(
        "4532-1234-5678-9012",
        "5555-4444-3333-2222",
        "4111-1111-1111-1111"
    )
    "DadosConfidenciais" = @(
        "CONFIDENCIAL - Relatório Interno",
        "RESTRITO - Acesso Limitado",
        "SIGILOSO - Não Divulgar",
        "CLASSIFIED - Internal Use Only"
    )
    "DadosPessoais" = @(
        "Nome: João Silva - CPF: 123.456.789-01 - Email: joao@empresa.com",
        "DADOS PESSOAIS: Maria Santos - Telefone: (11) 99999-9999",
        "PERSONAL DATA: John Doe - SSN: 123-45-6789"
    )
}

# Templates de documentos
$documentTemplates = @{
    "RelatorioFinanceiro" = @"
RELATÓRIO FINANCEIRO - CONFIDENCIAL
=====================================
Data: $(Get-Date -Format "dd/MM/yyyy")
Empresa: Empresa Fictícia LTDA

DADOS CONFIDENCIAIS - NÃO DIVULGAR

Informações de Funcionários:
- João Silva - CPF: 123.456.789-01 - Salário: R$ 5.000,00
- Maria Santos - CPF: 987.654.321-00 - Salário: R$ 7.500,00

Cartões Corporativos:
- Cartão Principal: 4532-1234-5678-9012
- Cartão Backup: 5555-4444-3333-2222

SENHA do sistema financeiro: admin123
PASSWORD do backup: secreto456

Este documento contém DADOS PESSOAIS e informações RESTRITAS.
Acesso limitado apenas ao departamento financeiro.
"@

    "ContratoFuncionario" = @"
CONTRATO DE TRABALHO - SIGILOSO
===============================
Data: $(Get-Date -Format "dd/MM/yyyy")

DADOS DO FUNCIONÁRIO:
Nome: Maria Silva Santos
CPF: 111.222.333-44
RG: 12.345.678-9
Telefone: (11) 98765-4321
Email: maria.santos@empresa.com

DADOS BANCÁRIOS:
Banco: 001 - Banco do Brasil
Agência: 1234-5
Conta: 67890-1

INFORMAÇÕES CONFIDENCIAIS:
- Salário: R$ 8.500,00
- Benefícios: R$ 1.200,00
- Código de acesso: senha123

Este documento é RESTRITO e contém PERSONAL DATA.
Manter em local seguro e não divulgar.
"@

    "PoliticaSeguranca" = @"
POLÍTICA DE SEGURANÇA - CLASSIFIED
==================================
Documento Interno - $(Get-Date -Format "dd/MM/yyyy")

SENHAS PADRÃO DO SISTEMA:
- Admin: password123
- Backup: confidencial456
- Suporte: SENHA789

DADOS DE ACESSO CONFIDENCIAIS:
- Servidor Principal: admin/secreto2024
- Banco de Dados: root/PASSWORD_ULTRA_SECRETO

CPFs de Administradores:
- Administrador 1: 555.666.777-88
- Administrador 2: 999.888.777-66

CARTÕES DE CRÉDITO CORPORATIVOS:
- Cartão Master: 4111-1111-1111-1111
- Cartão Visa: 4532-9876-5432-1098

ATENÇÃO: Este documento é SIGILOSO e contém informações CLASSIFIED.
Acesso restrito apenas ao departamento de TI.
"@

    "ListaClientes" = @"
LISTA DE CLIENTES - DADOS PESSOAIS
==================================
Atualizado em: $(Get-Date -Format "dd/MM/yyyy HH:mm")

ATENÇÃO: Este arquivo contém PERSONAL DATA

Cliente 1:
Nome: Carlos Eduardo Silva
CPF: 123.987.456-78
Telefone: (11) 91234-5678
Email: carlos@email.com
Cartão: 4532-1111-2222-3333

Cliente 2:
Nome: Ana Paula Santos
CPF: 456.123.789-01
Telefone: (21) 98765-4321
Email: ana@email.com
Cartão: 5555-9999-8888-7777

Cliente 3:
Nome: Roberto Oliveira
CPF: 789.456.123-45
Telefone: (31) 99999-1111
Email: roberto@email.com

DADOS CONFIDENCIAIS - Não compartilhar externamente
PASSWORD do sistema CRM: clientes123
"@

    "BackupSenhas" = @"
BACKUP DE SENHAS - ULTRA CONFIDENCIAL
====================================
Data do Backup: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")

ATENÇÃO: DOCUMENTO RESTRITO - ACESSO LIMITADO

Sistemas Críticos:
- ERP Principal: usuario=admin, senha=ERP_2024_SECRETO
- Banco de Dados: root/DATABASE_PASSWORD_123
- Email Corporativo: admin@empresa.com / password_email_456

Funcionários - Dados de Acesso:
- João (CPF: 111.222.333-44): joao123
- Maria (CPF: 555.666.777-88): maria456  
- Pedro (CPF: 999.888.777-66): pedro789

Cartões de Teste:
- Visa: 4111-1111-1111-1111
- Master: 5555-4444-3333-2222

Este arquivo é SIGILOSO e contém CLASSIFIED information.
DADOS PESSOAIS incluídos - manter segurança máxima.
"@
}

# Extensões de arquivo para testar
$fileExtensions = @("txt", "doc", "docx", "pdf")

Write-Host "Gerando $NumFiles arquivos de teste..." -ForegroundColor Yellow
Write-Host ""

for ($i = 1; $i -le $NumFiles; $i++) {
    # Selecionar template aleatório
    $templateNames = $documentTemplates.Keys | Get-Random -Count 1
    $template = $documentTemplates[$templateNames]
    
    # Selecionar extensão aleatória
    $extension = $fileExtensions | Get-Random
    
    # Adicionar dados sensíveis extras aleatórios
    $extraSensitiveData = ""
    $sensitiveData.Keys | ForEach-Object {
        $category = $_
        $randomData = $sensitiveData[$category] | Get-Random -Count 1
        $extraSensitiveData += "`n`nDados $category adicionais: $randomData"
    }
    
    # Criar conteúdo final
    $finalContent = $template + $extraSensitiveData
    
    # Nome do arquivo
    $fileName = "TestDocument_$i" + "_$(Get-Date -Format 'yyyyMMdd_HHmmss').$extension"
    $filePath = Join-Path $TestDataPath $fileName
    
    # Salvar arquivo
    $finalContent | Out-File -FilePath $filePath -Encoding UTF8
    
    Write-Host "✅ Criado: $fileName" -ForegroundColor Green
    if ($Verbose) {
        Write-Host "   Caminho: $filePath" -ForegroundColor Gray
        Write-Host "   Tamanho: $([math]::Round((Get-Item $filePath).Length / 1KB, 2)) KB" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "=== RESUMO DOS DADOS CRIADOS ===" -ForegroundColor Cyan
Write-Host "📁 Diretório: $TestDataPath" -ForegroundColor White
Write-Host "📄 Arquivos criados: $NumFiles" -ForegroundColor White
Write-Host ""

Write-Host "🔍 DADOS SENSÍVEIS INCLUÍDOS:" -ForegroundColor Yellow
Write-Host "   • CPFs fictícios (formato brasileiro)" -ForegroundColor White
Write-Host "   • Senhas e passwords" -ForegroundColor White
Write-Host "   • Números de cartão de crédito (teste)" -ForegroundColor White
Write-Host "   • Palavras-chave: CONFIDENCIAL, RESTRITO, SIGILOSO" -ForegroundColor White
Write-Host "   • Dados pessoais fictícios" -ForegroundColor White
Write-Host ""

Write-Host "📋 PRÓXIMOS PASSOS:" -ForegroundColor Cyan
Write-Host "1. Copie os arquivos para o FSx:" -ForegroundColor White
Write-Host "   Copy-Item '$TestDataPath\*' -Destination 'Z:\fsx-sync\' -Recurse" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Aguarde a sincronização com S3 (pode levar alguns minutos)" -ForegroundColor White
Write-Host ""
Write-Host "3. O Macie executará o scan diário e detectará os dados sensíveis" -ForegroundColor White
Write-Host ""
Write-Host "4. Verifique os alertas em:" -ForegroundColor White
Write-Host "   • Console do Macie: https://console.aws.amazon.com/macie/" -ForegroundColor Gray
Write-Host "   • CloudWatch Logs: /aws/lambda/fsx-compliance-poc-*" -ForegroundColor Gray
Write-Host "   • Email (se configurado)" -ForegroundColor Gray
Write-Host ""

Write-Host "⚠️  IMPORTANTE:" -ForegroundColor Red
Write-Host "   Estes são dados FICTÍCIOS para teste apenas!" -ForegroundColor White
Write-Host "   Não use dados reais em ambiente de teste." -ForegroundColor White
Write-Host ""

# Listar arquivos criados
Write-Host "📄 ARQUIVOS CRIADOS:" -ForegroundColor Cyan
Get-ChildItem $TestDataPath | ForEach-Object {
    $size = [math]::Round($_.Length / 1KB, 2)
    Write-Host "   $($_.Name) ($size KB)" -ForegroundColor White
}

Write-Host ""
Write-Host "✅ Geração de dados de teste concluída!" -ForegroundColor Green
