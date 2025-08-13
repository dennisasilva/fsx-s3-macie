# FSx for Windows Compliance PoC com Amazon Macie

Esta Prova de Conceito (PoC) demonstra como implementar uma solução completa de compliance para identificar e monitorar documentos sensíveis em um ambiente FSx for Windows usando serviços nativos da AWS.

## 🎯 Objetivo

Demonstrar como usar o Amazon Macie para identificar automaticamente documentos com informações sensíveis (PII, dados financeiros, palavras-chave específicas) armazenados no FSx for Windows, implementando alertas automáticos e ações de compliance.

## 📁 Estrutura do Projeto

O projeto está organizado em pastas por tipo de arquivo para facilitar a navegação e manutenção:

```
fsx-s3-macie/
├── README.md                    # Este arquivo (documentação principal)
├── ORGANIZATION-GUIDE.md        # Guia de organização do projeto
├── organize-project.sh          # Script de organização automática
├── test-paths.sh               # Script de teste de caminhos
├── scripts/                     # Scripts de automação
│   ├── powershell/             # Scripts PowerShell (.ps1)
│   └── bash/                   # Scripts Shell (.sh)
├── cloudformation/             # Templates CloudFormation
├── documentation/              # Documentação adicional do projeto
└── config/                     # Arquivos de configuração
```

## 🔧 Scripts Disponíveis

### PowerShell Scripts (`scripts/powershell/`)
- **`quick-compliance-test.ps1`** - Teste rápido de compliance
- **`run-compliance-test.ps1`** - Execução completa de testes de compliance
- **`monitor-compliance-findings.ps1`** - Monitoramento de findings do Macie
- **`download-scripts.ps1`** - Download de scripts auxiliares
- **`generate-test-data.ps1`** - Geração de dados de teste

### Bash Scripts (`scripts/bash/`)
- **`deploy-fsx-compliance-poc.sh`** - Script principal de deploy
- **`cleanup-orphan-buckets.sh`** - Limpeza de buckets órfãos
- **`validate-files.sh`** - Validação de arquivos
- **`test-debug.sh`** - Debug e testes
- **`debug-macie.sh`** - Debug específico do Macie
- **`fix-rollback-stacks.sh`** - Correção de stacks com rollback
- **`test-arn-format.sh`** - Teste de formato de ARNs
- **`compliance-test-linux.sh`** - Testes de compliance no Linux
- **`script-compliance-test.sh`** - Script de teste de compliance
- **`install-compliance-test.sh`** - Instalação de testes de compliance

### CloudFormation Templates (`cloudformation/`)
- **`fsx-storage.yaml`** - Template para FSx storage
- **`fsx-compliance-main.yaml`** - Template principal de compliance
- **`windows-client.yaml`** - Template para cliente Windows
- **`macie-processing.yaml`** - Template para processamento do Macie

### Documentação Adicional (`documentation/`)
- **`readme-compliance-test.md`** - Documentação dos testes de compliance
- **`arn-troubleshooting.md`** - Troubleshooting de ARNs
- **`rollback-handling.md`** - Tratamento de rollbacks
- **`fsx-integration-flows.md`** - Fluxos de integração FSx
- **`data-flow-diagram.md`** - Diagrama de fluxo de dados
- **`architecture-diagram.md`** - Diagrama de arquitetura
- **`fsx-macie-architecture.md`** - Arquitetura FSx + Macie
- **`fixes-applied.md`** - Correções aplicadas
- **`ssm-agent-troubleshooting.md`** - Troubleshooting do SSM Agent
- **`manual-domain-datasync-setup.md`** - Configuração manual de domínio e DataSync
- **`ami-final-update.md`** - Atualização final da AMI
- **`domain-datasync-improvements.md`** - Melhorias de domínio e DataSync

### Configurações (`config/`)
- **`parameters-example.json`** - Exemplo de parâmetros
- **`deployment-info.txt`** - Informações de deployment
- **`steps-script-compliance-test.txt`** - Passos dos testes
- **`.fsx-compliance-config`** - Configuração do projeto

## 🔒 Segurança e Acesso

Esta solução utiliza **AWS Systems Manager Session Manager** para acesso às instâncias, eliminando a necessidade de:
- ❌ Key pairs EC2
- ❌ Credenciais de longo prazo
- ❌ Acesso RDP direto
- ❌ Portas abertas para internet

✅ **Acesso seguro via AWS Systems Manager**
✅ **Funcionamento 100% automatizado**
✅ **IAM roles com least privilege**

## 🏗️ Arquitetura da Solução

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Windows EC2   │    │ FSx for Windows │    │   S3 Bucket     │
│                 │────│                 │────│                 │
│ - Auto config   │    │ - File Server   │    │ - Compliance    │
│ - SSM access    │    │ - Active Dir    │    │ - Versioning    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                                              │
         │                                              │
         ▼                                              ▼
┌─────────────────┐                            ┌─────────────────┐
│   Lambda        │                            │  Amazon Macie   │
│                 │                            │                 │
│ - Trigger jobs  │◄───────────────────────────│ - Data Discovery│
│ - Process events│                            │ - Classification│
└─────────────────┘                            └─────────────────┘
         │                                              │
         │                                              │
         ▼                                              ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   EventBridge   │    │      SNS        │    │   CloudWatch    │
│                 │────│                 │────│                 │
│ - Event routing │    │ - Notifications │    │ - Monitoring    │
│ - Pattern match │    │ - Email alerts  │    │ - Dashboards    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## 📋 Componentes da Solução

### 1. **Infraestrutura de Rede**
- VPC com subnets públicas e privadas
- NAT Gateway para acesso à internet
- VPC Endpoints para S3, Lambda e EventBridge
- Security Groups configurados

### 2. **Armazenamento**
- **FSx for Windows**: File server principal com Active Directory integrado
- **S3 Bucket**: Armazenamento intermediário para análise do Macie
- **Managed AD**: Active Directory gerenciado pela AWS

### 3. **Análise de Compliance**
- **Amazon Macie**: Descoberta e classificação de dados sensíveis
- **Custom Data Identifiers**: Regras personalizadas para palavras-chave específicas
- **Classification Jobs**: Jobs agendados e sob demanda

### 4. **Automação**
- **Lambda Functions**: Processamento de eventos e automação
- **EventBridge**: Roteamento de eventos do Macie
- **PowerShell Scripts**: Sincronização FSx → S3 (executados automaticamente)

### 5. **Monitoramento e Alertas**
- **SNS**: Notificações por email
- **CloudWatch**: Métricas e logs
- **CloudTrail**: Auditoria de ações

## 🚀 Deploy da Solução

### Pré-requisitos

1. **AWS CLI** configurado com credenciais apropriadas
2. **Email válido** para receber notificações
3. **Permissões IAM** para criar recursos (VPC, EC2, FSx, Macie, etc.)
4. **PowerShell** (para scripts .ps1)
5. **Bash** (para scripts .sh)

⚠️ **Não é necessário key-pair EC2** - a solução usa AWS Systems Manager

### AMI Otimizada

A solução utiliza **AMI Windows Server 2022 Full Base** (`ami-0758218dcb57e4a14` para us-east-1) que inclui:
- ✅ **SSM Agent pré-instalado** e configurado
- ✅ **Interface gráfica habilitada** (Desktop Experience)
- ✅ **Registro automático** no Systems Manager
- ✅ **Session Manager** funcionando imediatamente
- ✅ **Fleet Manager** (interface gráfica) disponível
- ✅ **RDP via túnel** totalmente funcional

### Passos de Deploy

1. **Preparar ambiente**:
```bash
# Navegar para o diretório
cd fsx-s3-macie/

# Configurar email (opcional - será solicitado durante deploy)
export NOTIFICATION_EMAIL="seu-email@exemplo.com"
export REGION="us-east-1"
```

2. **Executar deploy**:
```bash
# Execute o script principal de deploy (funciona de qualquer diretório)
./scripts/bash/deploy-fsx-compliance-poc.sh

# Ou navegue até a pasta do projeto e execute
cd /caminho/para/fsx-s3-macie
./scripts/bash/deploy-fsx-compliance-poc.sh
```

**Nota**: O script foi atualizado para funcionar com a nova estrutura de pastas e localizar automaticamente os templates CloudFormation na pasta `cloudformation/`.

3. **Escolher opção 1** para deploy completo

### Configuração Adicional

```bash
# Os arquivos de configuração estão na pasta config/
# Copie e edite o arquivo de parâmetros se necessário
cp config/parameters-example.json config/parameters.json
# Edite os parâmetros conforme necessário
```

### Tempo Estimado de Deploy
- **Infraestrutura principal**: ~5 minutos
- **FSx e S3**: ~15-20 minutos
- **Macie e processamento**: ~3 minutos
- **Cliente Windows**: ~10 minutos
- **Total**: ~35-40 minutos

## 🔍 Funcionalidades

- **Detecção Automática**: Identifica dados sensíveis usando Amazon Macie
- **Alertas em Tempo Real**: Notificações via SNS quando dados sensíveis são detectados
- **Compliance Contínuo**: Monitoramento contínuo de arquivos sincronizados
- **Relatórios Detalhados**: Geração de relatórios de compliance
- **Integração FSx-S3**: Sincronização automática entre FSx e S3

## 🤖 Funcionamento Automatizado

### ✅ **A solução funciona 100% automaticamente:**

1. **Configuração Automática**: Instância Windows se configura sozinha
2. **Ingresso no Domínio**: Instância ingressa automaticamente no Managed AD
3. **Mapeamento FSx**: Drive Z: mapeado automaticamente para o FSx
4. **Criação de Arquivos**: Cria arquivos de teste com dados sensíveis
5. **Sincronização DataSync**: FSx → S3 executada automaticamente via DataSync
6. **Detecção**: Macie escaneia e identifica dados sensíveis
7. **Alertas**: Notificações enviadas por email
8. **Agendamento**: Sincronização diária às 02:00 via DataSync

### 📧 **Alertas Automáticos**

Você receberá emails para:
- 🚨 **HIGH Severity**: PII, CPF, dados financeiros
- ⚠️ **MEDIUM Severity**: Palavras-chave (CONFIDENCIAL, RESTRITO)
- ℹ️ **LOW Severity**: Relatórios semanais

## 🧪 Testes de Compliance

### PowerShell (Windows)
```powershell
# Execute testes rápidos
./scripts/powershell/quick-compliance-test.ps1

# Ou execute testes completos
./scripts/powershell/run-compliance-test.ps1

# Monitore findings do Macie
./scripts/powershell/monitor-compliance-findings.ps1 -Continuous
```

### Bash (Linux/macOS)
```bash
# Execute testes no Linux
./scripts/bash/compliance-test-linux.sh

# Scripts de teste específicos
./scripts/bash/script-compliance-test.sh
./scripts/bash/install-compliance-test.sh
```

## 🔧 Acesso à Instância

### 🖥️ **Acesso Gráfico (Recomendado)**

A AMI utilizada (`ami-0758218dcb57e4a14`) tem **interface gráfica habilitada**, permitindo acesso visual completo:

#### **Opção 1: AWS Systems Manager Fleet Manager**
```bash
# Via Console AWS
AWS Console → Systems Manager → Fleet Manager → Select Instance → Remote Desktop
```
- ✅ **Interface gráfica completa** no browser
- ✅ **Sem portas abertas** no Security Group
- ✅ **Totalmente seguro** via AWS

#### **Opção 2: RDP via Túnel Session Manager**
```bash
# 1. Obter Instance ID
INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-windows \
    --query 'Stacks[0].Outputs[?OutputKey==`WindowsInstanceId`].OutputValue' \
    --output text)

# 2. Criar túnel RDP
aws ssm start-session \
    --target $INSTANCE_ID \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["3389"],"localPortNumber":["9999"]}' \
    --region us-east-1

# 3. Conectar RDP via túnel local
# Windows: mstsc /v:localhost:9999
# Mac: Microsoft Remote Desktop → localhost:9999
```
- ✅ **RDP tradicional** mas via túnel seguro
- ✅ **Interface gráfica completa**
- ✅ **Sem portas abertas** no Security Group

### 💻 **Acesso via Linha de Comando**

### Via AWS CLI:
```bash
# Obter Instance ID
aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-windows \
    --query 'Stacks[0].Outputs[?OutputKey==`WindowsInstanceId`].OutputValue' \
    --output text

# Conectar via Session Manager
aws ssm start-session --target i-1234567890abcdef0 --region us-east-1

# Para PowerShell
aws ssm start-session --target i-1234567890abcdef0 --region us-east-1 --document-name AWS-StartPowerShellSession
```

### Via Console AWS:
1. Acesse **EC2 Console**
2. Selecione a instância
3. Clique em **"Connect" → "Session Manager"**

## 🧪 Monitoramento da Solução

### 1. **Verificar Funcionamento**

```bash
# Status das stacks
./scripts/bash/deploy-fsx-compliance-poc.sh
# Escolher opção 6

# Informações da infraestrutura
./scripts/bash/deploy-fsx-compliance-poc.sh
# Escolher opção 7
```

### 2. **Locais de Monitoramento**

- **📧 Email**: Alertas de compliance em tempo real
- **📦 S3 Bucket**: `s3://fsx-compliance-poc-compliance-*/fsx-sync/`
- **🔍 Macie Console**: https://console.aws.amazon.com/macie/
- **📊 CloudWatch**: Logs em `/aws/lambda/fsx-compliance-poc-*`

### 3. **Arquivos de Teste Criados Automaticamente**

A solução cria automaticamente:
- `documento_confidencial_teste.txt` (com CPF, dados sensíveis)
- `relatorio_sigiloso_teste.txt` (com palavras CONFIDENCIAL, RESTRITO)
- `manual_usuario_teste.txt` (arquivo normal, sem dados sensíveis)

## 📝 Logs e Debug

Para debug e análise de logs:
```bash
# Debug do Macie
./scripts/bash/debug-macie.sh

# Testes de debug
./scripts/bash/test-debug.sh

# Validação de arquivos
./scripts/bash/validate-files.sh

# Executar DataSync manualmente
./scripts/bash/run-datasync.sh
```

## 🔧 **Configuração Manual (Se Necessário)**

Se a automação não funcionar completamente, consulte:
- `documentation/manual-domain-datasync-setup.md` - Configuração manual de domínio e DataSync

### **Problemas Comuns e Soluções:**

#### **1. Instância não ingressou no domínio**
```bash
# Verificar logs da instância
aws ssm start-session --target INSTANCE-ID --region us-east-1
# Dentro da instância: Get-Content C:\Windows\Temp\userdata.log

# Configuração manual: consulte o guia em documentation/
```

#### **2. FSx não está acessível**
```powershell
# Na instância Windows, verificar mapeamento
Get-PSDrive | Where-Object {$_.Provider -like "*FileSystem*"}

# Mapear manualmente se necessário
New-PSDrive -Name Z -PSProvider FileSystem -Root "\\FSX-DNS\share" -Persist
```

#### **3. DataSync não está sincronizando**
```bash
# Executar sincronização manual
./scripts/bash/run-datasync.sh

# Verificar status da tarefa
aws datasync list-task-executions --task-arn TASK-ARN --region us-east-1
```

## 🧹 Limpeza e Manutenção

Para limpar recursos órfãos:
```bash
# Limpar buckets órfãos
./scripts/bash/cleanup-orphan-buckets.sh

# Corrigir stacks com problemas
./scripts/bash/fix-rollback-stacks.sh

# Testar formato de ARNs
./scripts/bash/test-arn-format.sh
```

### Remover Infraestrutura Completa

```bash
# Usando o script
./scripts/bash/deploy-fsx-compliance-poc.sh
# Escolher opção 8

# Ou manualmente
aws cloudformation delete-stack --stack-name fsx-compliance-poc-windows
aws cloudformation delete-stack --stack-name fsx-compliance-poc-macie
aws cloudformation delete-stack --stack-name fsx-compliance-poc-storage
aws cloudformation delete-stack --stack-name fsx-compliance-poc-main
```

### Limpeza Manual

1. **S3 Bucket**: Esvaziar antes de deletar
2. **Macie**: Desabilitar sessão se necessário
3. **Snapshots**: Remover backups do FSx

## 📊 Resultados Esperados

### ⏱️ **Timeline:**
- **0-10 min**: Deploy da infraestrutura
- **10-15 min**: Configuração automática da instância
- **15-20 min**: Primeiros arquivos sincronizados para S3
- **20-25 min**: Macie inicia análise
- **25-30 min**: Primeiros alertas por email

### 📧 **Alertas Esperados:**
1. **🚨 HIGH**: Documento com CPF detectado
2. **⚠️ MEDIUM**: Arquivo com palavra "CONFIDENCIAL"
3. **⚠️ MEDIUM**: Arquivo com palavra "RESTRITO"

## 💰 Estimativa de Custos

### Custos Mensais (região us-east-1)

| Serviço | Configuração | Custo Estimado |
|---------|-------------|----------------|
| FSx for Windows | 32 GB SSD | $15-20 |
| EC2 t3.medium | 24/7 | $30-35 |
| S3 Standard-IA | 100 GB | $1-2 |
| Macie | 100 GB scanned | $40-50 |
| Managed AD | Standard | $90-100 |
| Lambda | 1000 executions | $1-2 |
| Outros (SNS, CloudWatch) | - | $5-10 |
| **Total** | - | **$182-219** |

### Otimizações de Custo

1. **FSx**: Use menor capacidade para testes
2. **EC2**: Pare quando não estiver testando
3. **S3**: Configure lifecycle policies
4. **Macie**: Limite escopo de scanning

## 🛠️ Troubleshooting

Consulte os arquivos de documentação para resolução de problemas:
- `documentation/arn-troubleshooting.md` - Problemas com ARNs
- `documentation/rollback-handling.md` - Problemas de rollback
- `documentation/fixes-applied.md` - Correções já aplicadas

### Problemas Comuns

#### 1. **Não recebo alertas por email**
```bash
# Verificar se SNS subscription foi confirmada
aws sns list-subscriptions --region us-east-1

# Verificar logs do Lambda
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/fsx-compliance"
```

#### 2. **Macie não detecta dados**
- Aguardar 15-20 minutos após deploy
- Verificar se arquivos estão no S3
- Confirmar que Macie está habilitado na região

#### 3. **Instância não se configura**
```bash
# Verificar logs da instância
aws ssm start-session --target INSTANCE-ID --region us-east-1
# Dentro da instância: Get-Content C:\Windows\Temp\userdata.log
```

## 🔒 Considerações de Segurança

### ✅ **Implementadas na PoC**

- **Encryption**: Em trânsito e repouso
- **IAM Roles**: Least privilege principle
- **VPC**: Subnets privadas
- **Security Groups**: Acesso restritivo
- **CloudTrail**: Auditoria completa
- **Session Manager**: Acesso seguro sem key-pairs

### 🔄 **Para Produção**

- Implementar AWS Config para compliance
- Usar AWS Secrets Manager para senhas
- Configurar GuardDuty
- Implementar backup cross-region
- Configurar alertas de segurança

## 📚 Recursos Adicionais

### Documentação AWS
- [Amazon FSx for Windows](https://docs.aws.amazon.com/fsx/latest/WindowsGuide/)
- [Amazon Macie](https://docs.aws.amazon.com/macie/)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)

### Diagramas e Arquitetura
- Consulte `documentation/architecture-diagram.md` para diagramas detalhados
- Use `documentation/data-flow-diagram.md` para entender o fluxo de dados
- Veja `documentation/fsx-macie-architecture.md` para arquitetura específica

## 📞 Suporte

Para suporte e dúvidas:
- Consulte a documentação completa em `documentation/`
- Verifique os logs do CloudWatch
- Use o AWS Support se necessário
- Execute os scripts de debug disponíveis

## 🤝 Contribuição

Para melhorias ou correções:
1. Identifique o problema
2. Teste a solução
3. Documente as mudanças
4. Compartilhe o feedback

---

**✅ Solução Segura**: Esta PoC usa AWS Systems Manager Session Manager, eliminando a necessidade de key-pairs e credenciais de longo prazo.

**🤖 Totalmente Automatizada**: Deploy e esqueça - a solução funciona sozinha e envia alertas por email.

**📁 Bem Organizada**: Projeto estruturado em pastas por tipo de arquivo para facilitar navegação e manutenção.

**⚠️ Aviso**: Esta é uma PoC para demonstração. Para uso em produção, implemente as considerações de segurança e otimizações mencionadas.

---

**Última atualização**: 13 de agosto de 2025
**Versão**: 2.0 (Consolidada)
