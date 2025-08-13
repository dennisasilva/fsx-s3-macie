# 🔒 FSx Compliance PoC - Guia de Teste Completo

Este guia mostra como executar um teste end-to-end da solução de compliance usando dados fictícios para disparar alertas do Amazon Macie.

## 📋 Pré-requisitos

- ✅ Infraestrutura FSx + Macie deployada com sucesso
- ✅ Instância Windows EC2 configurada e conectada ao FSx
- ✅ AWS CLI instalado e configurado na instância
- ✅ Acesso via AWS Systems Manager Session Manager

## 🚀 Scripts Disponíveis

### 1. `generate-test-data.ps1`
Gera arquivos com dados fictícios sensíveis para teste.

### 2. `run-compliance-test.ps1`
Executa o teste completo end-to-end.

### 3. `monitor-compliance-findings.ps1`
Monitora e exibe findings do Macie.

## 📖 Passo a Passo Completo

### Etapa 1: Conectar à Instância Windows

```bash
# Obter ID da instância
aws ec2 describe-instances --filters "Name=tag:Project,Values=fsx-compliance-poc" --query "Reservations[].Instances[].InstanceId" --output text

# Conectar via Session Manager
aws ssm start-session --target i-1234567890abcdef0
```

### Etapa 2: Baixar Scripts de Teste

Na instância Windows, execute no PowerShell:

```powershell
# Criar diretório para scripts
New-Item -ItemType Directory -Path "C:\ComplianceTest" -Force
Set-Location "C:\ComplianceTest"

# Baixar scripts (substitua pela URL do seu repositório)
# Ou copie os scripts manualmente para C:\ComplianceTest\
```

### Etapa 3: Executar Teste Completo

```powershell
# Executar teste completo (recomendado)
.\run-compliance-test.ps1 -NumTestFiles 5 -Verbose

# Ou executar etapas separadamente:

# 1. Gerar apenas dados de teste
.\generate-test-data.ps1 -NumFiles 3 -Verbose

# 2. Copiar manualmente para FSx
Copy-Item "C:\FSxTestData\*" -Destination "Z:\fsx-sync\" -Recurse -Force
```

### Etapa 4: Monitorar Resultados

```powershell
# Monitoramento básico
.\monitor-compliance-findings.ps1

# Monitoramento detalhado
.\monitor-compliance-findings.ps1 -ShowDetails -ExportReport

# Monitoramento contínuo (tempo real)
.\monitor-compliance-findings.ps1 -Continuous -RefreshInterval 300
```

## 📊 Dados de Teste Gerados

Os scripts criam arquivos com os seguintes tipos de dados sensíveis **FICTÍCIOS**:

### 🔍 Dados Detectados pelo Macie

| Tipo | Exemplos | Padrão |
|------|----------|---------|
| **CPF Brasileiro** | 123.456.789-01 | `\d{3}\.\d{3}\.\d{3}-\d{2}` |
| **Senhas** | senha: admin123 | `(senha\|password): \w+` |
| **Cartão de Crédito** | 4532-1234-5678-9012 | Números de teste válidos |
| **Palavras-chave** | CONFIDENCIAL, RESTRITO | Termos de classificação |
| **SSN (US)** | 123-45-6789 | `\d{3}-\d{2}-\d{4}` |

### 📄 Tipos de Documentos

1. **Relatório Financeiro** - Dados de funcionários e cartões
2. **Contrato de Funcionário** - Informações pessoais completas
3. **Política de Segurança** - Senhas e dados de acesso
4. **Lista de Clientes** - Dados pessoais de clientes
5. **Backup de Senhas** - Credenciais de sistemas

## ⏱️ Timeline Esperado

| Etapa | Tempo Estimado | Descrição |
|-------|----------------|-----------|
| **Geração de Dados** | 1-2 minutos | Scripts criam arquivos localmente |
| **Cópia para FSx** | 1-2 minutos | Arquivos copiados para drive Z: |
| **Sincronização S3** | 5-15 minutos | FSx sincroniza com bucket S3 |
| **Execução Macie** | Varia | Job agendado (diário) ou manual |
| **Detecção Findings** | 10-30 minutos | Após execução do job |
| **Alertas/Notificações** | 1-5 minutos | Após detecção |

## 🔔 Verificando Resultados

### 1. Console do Macie
```
https://console.aws.amazon.com/macie/
```
- Vá em **"Findings"** para ver detecções
- Vá em **"Jobs"** para ver status dos jobs
- Vá em **"Data identifiers"** para ver regras customizadas

### 2. CloudWatch Logs
```bash
# Logs do Lambda de processamento
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/fsx-compliance-poc"

# Ver logs recentes
aws logs tail /aws/lambda/fsx-compliance-poc-process-findings --follow
```

### 3. Via AWS CLI
```bash
# Listar findings
aws macie2 list-findings --region us-east-1

# Detalhes de um finding específico
aws macie2 get-findings --finding-ids "finding-id-aqui"

# Status dos jobs
aws macie2 list-classification-jobs --region us-east-1
```

### 4. Email (se configurado)
Verifique sua caixa de entrada para alertas automáticos.

## 🎯 Casos de Uso de Teste

### Teste 1: Detecção Básica
```powershell
# Gerar 3 arquivos simples
.\generate-test-data.ps1 -NumFiles 3

# Copiar para FSx
Copy-Item "C:\FSxTestData\*" -Destination "Z:\fsx-sync\" -Force

# Aguardar e monitorar
.\monitor-compliance-findings.ps1 -ShowDetails
```

### Teste 2: Volume Alto
```powershell
# Gerar muitos arquivos para teste de performance
.\generate-test-data.ps1 -NumFiles 20

# Executar teste completo
.\run-compliance-test.ps1 -NumTestFiles 20 -ForceImmediateTest
```

### Teste 3: Monitoramento Contínuo
```powershell
# Iniciar monitoramento em tempo real
.\monitor-compliance-findings.ps1 -Continuous -RefreshInterval 180

# Em outro terminal, adicionar novos arquivos
.\generate-test-data.ps1 -NumFiles 5 -TestDataPath "C:\NovosTestes"
```

## 🚨 Forçar Execução Imediata (Opcional)

Para não aguardar o job agendado diário:

### Via Console AWS
1. Acesse [Macie Console](https://console.aws.amazon.com/macie/)
2. Vá em **"Jobs"** → **"Create job"**
3. Selecione o bucket de compliance
4. Configure como **"One-time job"**
5. Em **"Schedule"** → **"Run job now"**
6. Execute imediatamente

### Via CLI (Avançado)
```bash
# Criar job one-time
aws macie2 create-classification-job \
  --job-type ONE_TIME \
  --name "compliance-test-immediate" \
  --s3-job-definition '{
    "bucketDefinitions": [{
      "accountId": "123456789012",
      "buckets": ["seu-bucket-compliance"]
    }]
  }'
```

## 📈 Interpretando Resultados

### Severidades
- 🔴 **HIGH**: Dados muito sensíveis (CPF, cartões, senhas)
- 🟡 **MEDIUM**: Dados moderadamente sensíveis
- 🟢 **LOW**: Dados potencialmente sensíveis

### Tipos Comuns de Findings
- **SensitiveData:S3Object/Personal** - Dados pessoais detectados
- **SensitiveData:S3Object/Credentials** - Credenciais encontradas
- **SensitiveData:S3Object/CustomIdentifier** - Padrões customizados

### Ações Recomendadas
1. **Revisar arquivos** com findings HIGH
2. **Mover/criptografar** dados sensíveis
3. **Restringir acesso** aos arquivos
4. **Treinar usuários** sobre políticas
5. **Implementar DLP** (Data Loss Prevention)

## 🧹 Limpeza Após Teste

```powershell
# Remover arquivos de teste do FSx
Remove-Item "Z:\fsx-sync\TestDocument_*" -Force

# Remover arquivos locais
Remove-Item "C:\FSxTestData" -Recurse -Force
Remove-Item "C:\ComplianceReports" -Recurse -Force

# Cancelar jobs de teste (se criados)
# aws macie2 cancel-classification-job --job-id "job-id-aqui"
```

## ⚠️ Avisos Importantes

- 🔒 **Dados Fictícios**: Todos os dados são FICTÍCIOS para teste
- 🚫 **Não usar dados reais**: Nunca use dados pessoais reais em testes
- 🧹 **Limpeza**: Sempre remova dados de teste após validação
- 💰 **Custos**: Monitore custos do Macie durante testes extensivos
- 🔐 **Segurança**: Este é um ambiente de demonstração

## 🆘 Troubleshooting

### Problema: "FSx não montado"
```powershell
# Verificar se FSx está disponível
Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.DriveType -eq 4}

# Remontar se necessário
net use Z: \\fs-1234567890abcdef0.fsx.us-east-1.amazonaws.com\share
```

### Problema: "Bucket S3 não encontrado"
```bash
# Listar buckets de compliance
aws s3 ls | grep compliance

# Verificar sincronização
aws s3 ls s3://seu-bucket-compliance/fsx-sync/ --recursive
```

### Problema: "Nenhum finding encontrado"
1. Verifique se o job do Macie executou
2. Confirme que os arquivos estão no S3
3. Verifique se o Custom Data Identifier está ativo
4. Aguarde mais tempo (pode levar até 30 minutos)

## 📞 Suporte

Para problemas ou dúvidas:
1. Verifique os logs do CloudWatch
2. Consulte a documentação do Macie
3. Use o AWS Support (se disponível)

---

**✅ Teste de Compliance Configurado com Sucesso!**

Agora você pode demonstrar como a solução detecta automaticamente dados sensíveis e gera alertas de compliance em tempo real.
