# 🔧 Configuração Manual - Domínio e DataSync

Este guia fornece instruções para configurar manualmente o ingresso no domínio e o DataSync, caso a automação não funcione.

## 🚨 **Quando Usar Este Guia**

Use este guia se:
- ❌ A instância não ingressou automaticamente no domínio
- ❌ O FSx não está acessível da instância
- ❌ O DataSync não foi configurado corretamente
- ❌ A sincronização FSx → S3 não está funcionando

> ⚠️ **AVISO DE SEGURANÇA — Manuseio da senha do Managed AD**
>
> A senha do Admin do Managed AD é uma credencial de **administrador de domínio**. Em qualquer passo deste guia:
>
> - **Nunca** imprima, cole, digite ou passe a senha como argumento de linha de comando (`ps`/`/proc/<pid>/cmdline`, `~/.bash_history`, scrollback do terminal e logs de sessão do SSM Session Manager/Fleet Manager capturam o valor em texto claro).
> - Prefira caminhos onde a senha seja lida **diretamente da fonte autoritativa** (SSM Parameter Store) por um processo não-interativo (`aws ssm send-command` com um documento `AWS-RunPowerShellScript`), ou canalizada por `stdin`/arquivo temporário com `chmod 600`.
> - Se o SSM Session Manager estiver com logging habilitado (CloudWatch Logs ou bucket S3 de session logs), **todo** o que você digitar nessa sessão — inclusive atribuições a variáveis PowerShell — será persistido. Trate essas sessões como se fossem públicas.
> - A instância Windows deste projeto executa `Start-Transcript -Path "C:\Windows\Temp\userdata.log"` (ver `cloudformation/windows-client.yaml`), portanto comandos executados durante o bootstrap também são transcritos localmente. Siga os passos de limpeza no final deste guia.
> - A automação em `cloudformation/windows-client.yaml` já lê o parâmetro `/<project>/ad/password` com permissão IAM mínima; este guia manual é apenas um fallback de troubleshooting.

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

### **1.2 Localizar o Parâmetro da Senha (NUNCA imprima o valor)**

> ⚠️ **Não execute `aws ssm get-parameter ... --output text` em um terminal.** O resultado vai para o scrollback, para pipes de ferramentas e, em alguns ambientes, para a história do shell. O objetivo abaixo é apenas identificar o **nome** do parâmetro, não o valor.

```bash
# Obter apenas o NOME do parâmetro (o valor fica no SSM)
PASSWORD_PARAM=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].Outputs[?OutputKey==`ADPasswordParameterName`].OutputValue' \
    --output text)

echo "Parâmetro SSM (nome, não valor): $PASSWORD_PARAM"
```

Sempre que possível, deixe a senha **dentro** do SSM e consuma-a diretamente de um processo não-interativo (ver 1.4 — opção A). Se você realmente precisar do valor na sua própria máquina, canalize-o diretamente para o consumidor, sem imprimir e sem armazenar em variável de shell:

```bash
# Exemplo: gravar temporariamente num arquivo só do operador, 0600, para consumo imediato
umask 077
TMP_PW=$(mktemp)
trap 'shred -u "$TMP_PW" 2>/dev/null || rm -f "$TMP_PW"' EXIT
aws ssm get-parameter \
    --name "$PASSWORD_PARAM" \
    --with-decryption \
    --region us-east-1 \
    --query 'Parameter.Value' \
    --output text > "$TMP_PW"
chmod 600 "$TMP_PW"
# Use "$TMP_PW" apenas como argumento de --password file://... (ver seção 3.2)
```

Em nenhuma hipótese **anote** a senha em notas, chats ou wikis.

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

Você tem duas opções — **prefira a Opção A**, que não abre um shell interativo na instância e não passa o segredo pelo canal do Session Manager.

#### **Opção A (recomendada): executar via `aws ssm send-command` sem registrar saída**

O documento `AWS-RunPowerShellScript` lê o parâmetro **dentro da instância** usando a role de EC2; a senha nunca sai do SSM e não passa pela sua estação de trabalho. Rode isto a partir da sua estação:

```bash
INSTANCE_ID="i-xxxxxxxxxxxxxxxxx"            # id da instância Windows
PROJECT="fsx-compliance-poc"                 # nome do projeto
AD_PARAM="/$PROJECT/ad/password"             # parâmetro criado por fsx-storage.yaml
DOMAIN="$PROJECT.local"

# Envia o script e NUNCA guarda a saída em CloudWatch/S3 (sem --cloud-watch-output-config,
# sem --output-s3-bucket-name). A saída fica apenas no retorno síncrono da chamada.
aws ssm send-command \
    --document-name "AWS-RunPowerShellScript" \
    --instance-ids "$INSTANCE_ID" \
    --comment "domain-join (no output capture)" \
    --parameters commands='["
        $ErrorActionPreference = \"Stop\";
        $pw = (Get-SSMParameterValue -Name \"'"$AD_PARAM"'\" -WithDecryption $true).Parameters[0].Value;
        $sec = ConvertTo-SecureString $pw -AsPlainText -Force;
        Remove-Variable pw;
        $cred = New-Object System.Management.Automation.PSCredential(\"'"$DOMAIN"'\\Admin\", $sec);
        Add-Computer -DomainName \"'"$DOMAIN"'\" -Credential $cred -Restart -Force;
    "]' \
    --query 'Command.CommandId' --output text
```

Notas:
- `Get-SSMParameterValue` dentro da instância depende do SSM Agent + role de EC2 (já provisionada no `windows-client.yaml`).
- **Não** adicione `--cloud-watch-output-config` nem `--output-s3-bucket-name`: isso faria com que a saída stdout/stderr do Run Command (que pode conter diagnósticos sensíveis) fosse persistida.
- Se o seu account aplica Session Manager / Run Command logging por default (verifique `aws ssm get-service-setting --setting-id arn:aws:ssm:<region>:<acct>:servicesetting/ssm/sessionmanager/run-command-preferences`), **o Run Command também é capturado** — nesse caso, confirme com o time de segurança antes de prosseguir.

#### **Opção B (fallback): sessão interativa no Session Manager**

Apenas se a Opção A estiver indisponível. **Nunca** faça `$domainPassword = "..."` com a senha literal; isso é persistido tanto pelo log de sessão quanto pelo `Start-Transcript` ativo nesta instância (`C:\Windows\Temp\userdata.log`).

```powershell
# ANTES de qualquer coisa, desative transcript da sessão corrente e
# garanta que PSReadLine não adicione a linha ao histórico
try { Stop-Transcript | Out-Null } catch { }
Set-PSReadLineOption -HistorySaveStyle SaveNothing

$domainName = "fsx-compliance-poc.local"
$domainUser = "Admin"

# Lê a senha direto do SSM com a role da própria instância (nunca digitada no console).
# A senha permanece como SecureString; nunca é convertida de volta para texto claro.
$plain = (Get-SSMParameterValue -Name "/fsx-compliance-poc/ad/password" -WithDecryption $true).Parameters[0].Value
$securePassword = ConvertTo-SecureString $plain -AsPlainText -Force
Remove-Variable plain
[System.GC]::Collect()

$credential = New-Object System.Management.Automation.PSCredential("$domainName\$domainUser", $securePassword)

# Alternativa 100% interativa, caso Get-SSMParameterValue não esteja disponível:
# $securePassword = Read-Host -AsSecureString -Prompt "Senha do Admin do domínio"
# $credential     = New-Object System.Management.Automation.PSCredential("$domainName\$domainUser", $securePassword)

# Ingressar no domínio
Add-Computer -DomainName $domainName -Credential $credential -Restart -Force
```

**A instância será reiniciada automaticamente.** Depois do reboot, execute os passos de limpeza em **Parte 5 — Higiene de Credenciais**.

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

> ⚠️ **Não use o `Admin` do Managed AD como service account do DataSync.** O `Admin` é um usuário de domínio com privilégios totais; se o SMB cache dessa credencial for comprometido na EC2 ou se os logs do DataSync a vazarem, você perde o domínio inteiro, não apenas o share.
>
> Crie, uma única vez, um **usuário delegado** (ex.: `svc-datasync`) membro apenas do grupo `AWS Delegated FSx Administrators` (ou de um grupo customizado com permissões NTFS/SMB mínimas sobre o share) e use **ele** aqui. Troque a senha dele periodicamente e armazene-a como `SecureString` em outro parâmetro SSM (p.ex. `/fsx-compliance-poc/datasync/svc-password`), com acesso restrito à role do operador.

Se o DataSync não foi criado automaticamente, execute os passos abaixo. **A senha nunca aparece como argumento de linha de comando** — é lida direto do SSM e passada ao AWS CLI por `file://`.

```bash
set -euo pipefail
umask 077

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

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Nome do parâmetro SSM contendo a senha do service account delegado do DataSync.
# NUNCA aponte isto para o parâmetro do Admin do domínio.
SVC_USER="svc-datasync"
SVC_PARAM="/fsx-compliance-poc/datasync/svc-password"

# 1) Materializar a senha num arquivo temporário 0600, limpo no exit.
#    O arquivo serve apenas para o AWS CLI ler via file:// e nunca aparece em `ps`.
PWFILE=$(mktemp)
chmod 600 "$PWFILE"
trap 'shred -u "$PWFILE" 2>/dev/null || rm -f "$PWFILE"' EXIT

aws ssm get-parameter \
    --name "$SVC_PARAM" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text > "$PWFILE"

# 2) Criar localização FSx — observe `--password file://...`, não uma literal.
#    A senha não aparece em /proc/<pid>/cmdline nem em ~/.bash_history.
FSX_LOCATION=$(aws datasync create-location-fsx-windows \
    --fsx-filesystem-arn "$FSX_ARN" \
    --security-group-arns "arn:aws:ec2:us-east-1:${ACCOUNT_ID}:security-group/${SECURITY_GROUP}" \
    --user "$SVC_USER" \
    --password "file://$PWFILE" \
    --domain "fsx-compliance-poc.local" \
    --query 'LocationArn' \
    --output text)

# 3) O trap acima limpa $PWFILE no fim do script. Forçamos também aqui para
#    minimizar a janela em que o arquivo existe em disco.
shred -u "$PWFILE" 2>/dev/null || rm -f "$PWFILE"
trap - EXIT

# Criar localização S3
S3_LOCATION=$(aws datasync create-location-s3 \
    --s3-bucket-arn "$BUCKET_ARN" \
    --subdirectory "/fsx-sync/" \
    --s3-config BucketAccessRoleArn="arn:aws:iam::${ACCOUNT_ID}:role/fsx-compliance-poc-datasync-role" \
    --query 'LocationArn' \
    --output text)

# Criar tarefa DataSync
TASK_ARN=$(aws datasync create-task \
    --source-location-arn "$FSX_LOCATION" \
    --destination-location-arn "$S3_LOCATION" \
    --name "fsx-compliance-poc-manual-sync" \
    --query 'TaskArn' \
    --output text)

echo "✅ DataSync criado: $TASK_ARN"
```

> 💡 Alternativa com `stdin`: algumas versões do AWS CLI aceitam `--password file:///dev/stdin` + `aws ssm get-parameter ... | aws datasync ...`. Use somente se tiver certeza que a sua versão do CLI suporta esse padrão; caso contrário permaneça com o arquivo temporário 0600 acima.

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

## 🧼 **Parte 5: Higiene de Credenciais (OBRIGATÓRIO após qualquer um dos passos manuais)**

Mesmo seguindo as boas práticas acima, execute **todos** estes passos de limpeza ao final da sessão:

### **5.1 Na estação do operador (Linux/macOS/WSL)**

```bash
# Remover qualquer arquivo temporário de senha porventura esquecido
find /tmp -maxdepth 1 -user "$USER" -name 'tmp.*' -perm 600 -mtime -1 -exec shred -u {} \; 2>/dev/null

# Apagar linhas do histórico do shell que contenham referências a este fluxo
# (NB: também limpa a sessão atual; comandos ainda não-flushed são perdidos)
history -c && history -w

# Opcional e mais agressivo: zerar o arquivo de histórico persistente
: > "${HISTFILE:-$HOME/.bash_history}"
```

### **5.2 Na instância Windows (via Session Manager/RDP)**

```powershell
# Encerrar o transcript iniciado pelo user-data e remover o arquivo
try { Stop-Transcript | Out-Null } catch { }
Remove-Item -Force -ErrorAction SilentlyContinue "C:\Windows\Temp\userdata.log"

# Limpar completamente o histórico do PSReadLine do usuário corrente
$psrlHist = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
if (Test-Path $psrlHist) { Remove-Item -Force $psrlHist }
Clear-History

# Desligar persistência de histórico para o restante da sessão
Set-PSReadLineOption -HistorySaveStyle SaveNothing
```

### **5.3 Rotacionar a credencial se houver qualquer dúvida de exposição**

Se qualquer um destes aconteceu, **rotacione a senha** no Managed AD e atualize o parâmetro SSM:

- A senha foi impressa em terminal, chat, ticket, print de tela ou wiki.
- A sessão do Session Manager/Run Command tinha logging habilitado (CloudWatch Logs ou bucket S3 de session logs).
- Um `aws datasync create-location-fsx-windows --password "..."` com valor literal foi executado antes desta correção do runbook.
- O arquivo `C:\Windows\Temp\userdata.log` foi copiado para outro local antes do passo 5.2.

```bash
# 1) Reset no Managed AD
aws ds reset-user-password \
    --directory-id "$MANAGED_AD_ID" \
    --user-name Admin \
    --new-password "$(aws secretsmanager get-random-password \
        --exclude-characters '\"@/\\' --password-length 32 \
        --query RandomPassword --output text)"

# 2) Atualizar o parâmetro SSM. Idealmente converter para SecureString:
aws ssm put-parameter \
    --name "/fsx-compliance-poc/ad/password" \
    --type SecureString \
    --overwrite \
    --value "file:///dev/stdin" <<< "<nova senha gerada acima>"
```

> 🚧 **Débito técnico conhecido:** o parâmetro `/<project>/ad/password` em `cloudformation/fsx-storage.yaml` está criado como `Type: String` (texto claro). Deve ser migrado para `SecureString` com chave KMS dedicada; qualquer principal com `ssm:GetParameter` sobre esse ARN e `kms:Decrypt` sobre a CMK poderá lê-la, mas isso é estritamente melhor do que o estado atual.

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
