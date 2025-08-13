# 🔧 Configuração Manual - Domínio e DataSync

Este guia fornece instruções para configurar manualmente o ingresso no domínio e o DataSync, caso a automação não funcione.

## 🚨 **Quando Usar Este Guia**

Use este guia se:
- ❌ A instância não ingressou automaticamente no domínio
- ❌ O FSx não está acessível da instância
- ❌ O DataSync não foi configurado corretamente
- ❌ A sincronização FSx → S3 não está funcionando

## 🔐 **Parte 1: Ingresso Manual no Domínio**

### **1.1 Obter Informações do Managed AD**

```bash
# Obter ID do Managed AD
MANAGED_AD_ID=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedADId`].OutputValue' \
    --output text)

# Obter informações detalhadas
aws ds describe-directories --directory-ids $MANAGED_AD_ID --region us-east-1
```

**Anote:**
- **Nome do domínio**: `fsx-compliance-poc.local` (ou similar)
- **IPs DNS**: Ex: `10.0.1.123, 10.0.3.456`
- **Status**: Deve ser `Active`

### **1.2 Obter Senha do Administrador**

```bash
# Obter nome do parâmetro da senha
PASSWORD_PARAM=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`ADPasswordParameterName`].OutputValue' \
    --output text)

# Obter a senha
aws ssm get-parameter --name $PASSWORD_PARAM --with-decryption --region us-east-1 --query 'Parameter.Value' --output text
```

**Anote a senha** - você precisará dela para ingressar no domínio.

### **1.3 Configurar DNS na Instância Windows**

Acesse a instância via Session Manager ou Fleet Manager:

```powershell
# Verificar adaptadores de rede
Get-NetAdapter | Where-Object {$_.Status -eq "Up"}

# Configurar DNS (substitua pelos IPs do seu Managed AD)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "10.0.1.123","10.0.3.456"

# Verificar configuração
Get-DnsClientServerAddress
```

### **1.4 Ingressar no Domínio**

```powershell
# Definir variáveis (substitua pelos seus valores)
$domainName = "fsx-compliance-poc.local"
$domainUser = "Admin"
$domainPassword = "SUA_SENHA_AQUI"

# Criar credencial
$securePassword = ConvertTo-SecureString $domainPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("$domainName\$domainUser", $securePassword)

# Ingressar no domínio
Add-Computer -DomainName $domainName -Credential $credential -Restart -Force
```

**A instância será reiniciada automaticamente.**

### **1.5 Verificar Ingresso no Domínio**

Após o reinício, verifique:

```powershell
# Verificar se está no domínio
Get-ComputerInfo | Select-Object CsDomain, CsDomainRole

# Testar conectividade com o domínio
Test-ComputerSecureChannel -Verbose

# Verificar usuários do domínio
Get-ADUser -Filter * -Server $domainName
```

## 📁 **Parte 2: Configurar Acesso ao FSx**

### **2.1 Obter Informações do FSx**

```bash
# Obter DNS do FSx
FSX_DNS=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`FSxDNSName`].OutputValue' \
    --output text)

echo "FSx DNS: $FSX_DNS"
```

### **2.2 Mapear Drive do FSx**

Na instância Windows (após ingresso no domínio):

```powershell
# Definir variáveis
$fsxDns = "SEU_FSX_DNS_AQUI"  # Ex: fs-1234567890abcdef0.fsx-compliance-poc.local
$driveLetter = "Z"

# Mapear drive
New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root "\\$fsxDns\share" -Persist

# Verificar mapeamento
Get-PSDrive -Name $driveLetter

# Testar acesso
Test-Path "${driveLetter}:\"
```

### **2.3 Criar Estrutura de Pastas**

```powershell
# Criar pastas para compliance
$compliancePath = "Z:\ComplianceDocs"
New-Item -ItemType Directory -Path $compliancePath -Force

# Criar arquivos de teste
$testFiles = @(
    @{Name="documento_confidencial.txt"; Content="Este documento contém CPF: 123.456.789-00 e dados sensíveis."},
    @{Name="relatorio_sigiloso.txt"; Content="CONFIDENCIAL - Relatório RESTRITO para uso interno apenas."},
    @{Name="manual_usuario.txt"; Content="Manual do usuário - documento público sem dados sensíveis."}
)

foreach ($file in $testFiles) {
    $filePath = Join-Path $compliancePath $file.Name
    $file.Content | Out-File -FilePath $filePath -Encoding UTF8
    Write-Host "✅ Criado: $filePath"
}
```

## 🔄 **Parte 3: Configurar DataSync Manualmente**

### **3.1 Verificar se DataSync foi Criado**

```bash
# Verificar tarefa DataSync
DATASYNC_TASK=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`DataSyncTaskArn`].OutputValue' \
    --output text)

if [ "$DATASYNC_TASK" != "None" ]; then
    echo "✅ DataSync configurado: $DATASYNC_TASK"
else
    echo "❌ DataSync não configurado - será necessário criar manualmente"
fi
```

### **3.2 Criar DataSync Manualmente (se necessário)**

Se o DataSync não foi criado automaticamente:

```bash
# Obter informações necessárias
FSX_ARN=$(aws fsx describe-file-systems \
    --query 'FileSystems[?Tags[?Key==`Project` && Value==`fsx-compliance-poc`]].ResourceARN' \
    --output text)

BUCKET_ARN=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketArn`].OutputValue' \
    --output text)

SECURITY_GROUP=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-main \
    --query 'Stacks[0].Outputs[?OutputKey==`FSxSecurityGroupId`].OutputValue' \
    --output text)

# Criar localização FSx
FSX_LOCATION=$(aws datasync create-location-fsx-windows \
    --fsx-filesystem-arn $FSX_ARN \
    --security-group-arns "arn:aws:ec2:us-east-1:$(aws sts get-caller-identity --query Account --output text):security-group/$SECURITY_GROUP" \
    --user Admin \
    --password "SUA_SENHA_AD_AQUI" \
    --domain "fsx-compliance-poc.local" \
    --query 'LocationArn' \
    --output text)

# Criar localização S3
S3_LOCATION=$(aws datasync create-location-s3 \
    --s3-bucket-arn $BUCKET_ARN \
    --subdirectory "/fsx-sync/" \
    --s3-config BucketAccessRoleArn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/fsx-compliance-poc-datasync-role" \
    --query 'LocationArn' \
    --output text)

# Criar tarefa DataSync
TASK_ARN=$(aws datasync create-task \
    --source-location-arn $FSX_LOCATION \
    --destination-location-arn $S3_LOCATION \
    --name "fsx-compliance-poc-manual-sync" \
    --query 'TaskArn' \
    --output text)

echo "✅ DataSync criado: $TASK_ARN"
```

### **3.3 Executar Sincronização**

```bash
# Usar o script automatizado
./scripts/bash/run-datasync.sh

# Ou executar manualmente
aws datasync start-task-execution --task-arn $TASK_ARN --region us-east-1
```

## 🔍 **Parte 4: Verificação e Troubleshooting**

### **4.1 Verificar Conectividade FSx**

Na instância Windows:

```powershell
# Testar conectividade com FSx
Test-NetConnection -ComputerName "SEU_FSX_DNS" -Port 445

# Verificar se o drive está mapeado
Get-PSDrive | Where-Object {$_.Provider -like "*FileSystem*"}

# Listar arquivos no FSx
Get-ChildItem Z:\ -Recurse
```

### **4.2 Verificar Sincronização S3**

```bash
# Listar arquivos sincronizados
BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketName`].OutputValue' \
    --output text)

aws s3 ls "s3://$BUCKET_NAME/fsx-sync/" --recursive --human-readable
```

### **4.3 Verificar Logs do DataSync**

```bash
# Verificar execuções do DataSync
aws datasync list-task-executions --task-arn $TASK_ARN --region us-east-1

# Verificar logs no CloudWatch
aws logs describe-log-groups --log-group-name-prefix "/aws/datasync"
```

## 📋 **Checklist de Verificação**

### **Domínio:**
- [ ] Managed AD está `Active`
- [ ] DNS configurado na instância
- [ ] Instância ingressou no domínio
- [ ] Conectividade com controlador de domínio

### **FSx:**
- [ ] FSx está `AVAILABLE`
- [ ] Drive mapeado na instância
- [ ] Arquivos de teste criados
- [ ] Permissões de acesso funcionando

### **DataSync:**
- [ ] Tarefa DataSync criada
- [ ] Localizações FSx e S3 configuradas
- [ ] Execução manual funciona
- [ ] Arquivos aparecem no S3

### **Macie:**
- [ ] Bucket S3 sendo monitorado
- [ ] Jobs de classificação executando
- [ ] Findings sendo gerados
- [ ] Alertas por email funcionando

## 🚨 **Problemas Comuns**

### **1. Erro de Autenticação no Domínio**
```
Solução: Verificar senha do AD e configuração DNS
```

### **2. FSx Inacessível**
```
Solução: Verificar ingresso no domínio e Security Groups
```

### **3. DataSync Falha**
```
Solução: Verificar permissões IAM e conectividade de rede
```

### **4. Arquivos Não Sincronizam**
```
Solução: Verificar se há arquivos no FSx e permissões de leitura
```

## 📞 **Suporte**

Se os problemas persistirem:

1. **Colete logs:**
   - UserData: `C:\Windows\Temp\userdata.log`
   - DataSync: CloudWatch Logs
   - FSx: Event Viewer

2. **Verifique configurações:**
   - DNS da instância
   - Status do Managed AD
   - Permissões IAM

3. **Execute diagnósticos:**
   - `./scripts/bash/verify-ssm-agent.sh`
   - `./scripts/bash/run-datasync.sh`

---

**Última atualização**: 13 de agosto de 2025
**Status**: ✅ Guia completo para configuração manual
