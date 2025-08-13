# Fluxos de Dados e Integrações - FSx Compliance PoC

## 🔄 Fluxo de Dados Principal

```mermaid
graph LR
    subgraph "📁 Origem dos Dados"
        U1[👤 Usuário 1<br/>Salva contrato.pdf]
        U2[👤 Usuário 2<br/>Salva relatorio.xlsx]
        U3[👤 Usuário 3<br/>Salva manual.txt]
        APP[🖥️ Aplicação<br/>Gera logs.csv]
    end
    
    subgraph "🗂️ FSx for Windows"
        FSX_DOCS[📂 /ComplianceDocs/<br/>├── contratos/<br/>├── relatorios/<br/>├── manuais/<br/>└── logs/]
    end
    
    subgraph "💻 EC2 Processing"
        PS_MONITOR[👁️ PowerShell Monitor<br/>FileSystemWatcher<br/>Real-time detection]
        PS_SYNC[🔄 PowerShell Sync<br/>Scheduled task<br/>Daily at 02:00]
        PS_FILTER[🔍 File Filter<br/>Extensions: pdf, doc, docx,<br/>txt, xlsx, ppt, pptx]
    end
    
    subgraph "📦 S3 Storage"
        S3_STRUCTURE[📁 S3 Structure<br/>fsx-compliance-bucket/<br/>├── fsx-sync/<br/>│   ├── contratos/<br/>│   ├── relatorios/<br/>│   ├── manuais/<br/>│   └── logs/<br/>└── metadata/]
    end
    
    subgraph "🔍 Macie Analysis"
        MACIE_SCAN[🔍 Content Scanning<br/>- Text extraction<br/>- Pattern matching<br/>- ML classification]
        MACIE_RULES[📋 Detection Rules<br/>- Built-in: PII, Financial<br/>- Custom: CONFIDENCIAL<br/>- Regex: CPF patterns]
    end
    
    subgraph "📊 Results Processing"
        FINDINGS[📊 Findings Database<br/>- Severity scores<br/>- Data types<br/>- Risk levels<br/>- Timestamps]
        CLASSIFICATION[🏷️ Classification<br/>HIGH: PII/Financial<br/>MEDIUM: Keywords<br/>LOW: Clean data]
    end
    
    U1 --> FSX_DOCS
    U2 --> FSX_DOCS
    U3 --> FSX_DOCS
    APP --> FSX_DOCS
    
    FSX_DOCS --> PS_MONITOR
    FSX_DOCS --> PS_SYNC
    PS_MONITOR --> PS_FILTER
    PS_SYNC --> PS_FILTER
    PS_FILTER --> S3_STRUCTURE
    
    S3_STRUCTURE --> MACIE_SCAN
    MACIE_RULES --> MACIE_SCAN
    MACIE_SCAN --> FINDINGS
    FINDINGS --> CLASSIFICATION
```

## 🚨 Fluxo de Alertas e Notificações

```mermaid
graph TD
    subgraph "📊 Macie Findings"
        F_HIGH[🚨 HIGH Severity<br/>Score: 8.0-10.0<br/>- PII detected<br/>- Financial data<br/>- Medical records]
        F_MED[⚠️ MEDIUM Severity<br/>Score: 4.0-7.9<br/>- Custom keywords<br/>- Business sensitive<br/>- Internal use only]
        F_LOW[ℹ️ LOW Severity<br/>Score: 0.0-3.9<br/>- Public information<br/>- General content<br/>- No sensitive data]
    end
    
    subgraph "📡 EventBridge Routing"
        EB_PATTERN[🎯 Event Patterns<br/>source: aws.macie<br/>detail-type: Macie Finding<br/>severity: HIGH/MEDIUM/LOW]
    end
    
    subgraph "⚡ Lambda Processing"
        L_PROCESS[🔄 Process Finding<br/>- Extract metadata<br/>- Determine actions<br/>- Route notifications]
        L_ENRICH[📝 Enrich Data<br/>- Add context<br/>- Calculate risk<br/>- Generate summary]
    end
    
    subgraph "📨 Notification Channels"
        subgraph "🚨 Critical Path (HIGH)"
            EMAIL_CRIT[📧 Immediate Email<br/>To: security@company.com<br/>Subject: CRITICAL ALERT]
            SMS_CRIT[📱 SMS Alert<br/>To: Security team<br/>Message: Data breach risk]
            SLACK_CRIT[💬 Slack Alert<br/>Channel: #security-alerts<br/>Mention: @security-team]
        end
        
        subgraph "⚠️ Standard Path (MEDIUM)"
            EMAIL_STD[📧 Standard Email<br/>To: compliance@company.com<br/>Subject: Compliance Review]
            TICKET[🎫 Service Ticket<br/>System: ServiceNow<br/>Priority: Medium]
        end
        
        subgraph "ℹ️ Reporting Path (LOW)"
            DASHBOARD[📊 Dashboard Update<br/>System: QuickSight<br/>Frequency: Real-time]
            REPORT[📋 Weekly Report<br/>To: Management<br/>Format: PDF summary]
        end
    end
    
    F_HIGH --> EB_PATTERN
    F_MED --> EB_PATTERN
    F_LOW --> EB_PATTERN
    
    EB_PATTERN --> L_PROCESS
    L_PROCESS --> L_ENRICH
    
    L_ENRICH --> EMAIL_CRIT
    L_ENRICH --> SMS_CRIT
    L_ENRICH --> SLACK_CRIT
    L_ENRICH --> EMAIL_STD
    L_ENRICH --> TICKET
    L_ENRICH --> DASHBOARD
    L_ENRICH --> REPORT
```

## 🔄 Ciclo de Vida dos Dados

```mermaid
stateDiagram-v2
    [*] --> Created : Arquivo criado no FSx
    
    Created --> Detected : PowerShell detecta mudança
    Detected --> Filtered : Verifica extensão suportada
    
    Filtered --> Ignored : Extensão não suportada
    Filtered --> Queued : Extensão suportada
    
    Queued --> Syncing : Inicia sincronização S3
    Syncing --> Synced : Upload concluído
    Syncing --> SyncError : Erro na sincronização
    
    SyncError --> Retry : Tentativa automática
    Retry --> Syncing : Reprocessar
    Retry --> Failed : Máximo de tentativas
    
    Synced --> Scanning : Macie inicia análise
    Scanning --> Analyzed : Análise concluída
    Scanning --> ScanError : Erro na análise
    
    ScanError --> Retry
    
    Analyzed --> Classified : Classificação aplicada
    Classified --> NotificationSent : Alertas enviados
    
    NotificationSent --> Archived : Dados arquivados
    Ignored --> Archived
    Failed --> Archived
    
    Archived --> [*] : Ciclo completo
    
    note right of Created
        Tipos suportados:
        - PDF, DOC, DOCX
        - TXT, CSV
        - XLS, XLSX
        - PPT, PPTX
    end note
    
    note right of Classified
        Classificações:
        - HIGH: PII/Financial
        - MEDIUM: Keywords
        - LOW: Clean data
    end note
```

## 🏗️ Arquitetura de Deployment

```mermaid
graph TB
    subgraph "🚀 CloudFormation Stacks"
        subgraph "Stack 1: Infrastructure"
            CF1[📋 fsx-compliance-main.yaml<br/>- VPC & Networking<br/>- Security Groups<br/>- VPC Endpoints<br/>- IAM Roles]
        end
        
        subgraph "Stack 2: Storage"
            CF2[📋 fsx-storage.yaml<br/>- FSx File System<br/>- S3 Bucket<br/>- Managed AD<br/>- Lambda Triggers]
        end
        
        subgraph "Stack 3: Security"
            CF3[📋 macie-processing.yaml<br/>- Macie Configuration<br/>- Custom Identifiers<br/>- EventBridge Rules<br/>- SNS Topics]
        end
        
        subgraph "Stack 4: Compute"
            CF4[📋 windows-client.yaml<br/>- EC2 Instance<br/>- PowerShell Scripts<br/>- Scheduled Tasks<br/>- SSM Configuration]
        end
    end
    
    subgraph "📦 Dependencies"
        DEP1[🔗 Stack Dependencies<br/>CF1 → CF2 → CF3 → CF4<br/>Export/Import Values<br/>Cross-stack References]
    end
    
    subgraph "🔧 Deployment Process"
        DEPLOY[🚀 deploy-fsx-compliance-poc.sh<br/>- Pre-requisite checks<br/>- Sequential deployment<br/>- Error handling<br/>- Status validation]
        VALIDATE[✅ validate-files.sh<br/>- File integrity<br/>- Reference validation<br/>- Syntax checking<br/>- Dependency verification]
    end
    
    CF1 --> CF2
    CF2 --> CF3
    CF3 --> CF4
    
    CF1 --> DEP1
    CF2 --> DEP1
    CF3 --> DEP1
    CF4 --> DEP1
    
    VALIDATE --> DEPLOY
    DEPLOY --> CF1
```

## 📊 Métricas e KPIs

```mermaid
graph LR
    subgraph "📈 Operational Metrics"
        OP1[📁 Files Processed<br/>- Total files scanned<br/>- Files per day<br/>- Processing rate<br/>- Queue depth]
        OP2[⏱️ Performance<br/>- Sync latency<br/>- Scan duration<br/>- End-to-end time<br/>- Error rates]
        OP3[💰 Cost Metrics<br/>- S3 storage costs<br/>- Macie scan costs<br/>- Lambda execution<br/>- Data transfer]
    end
    
    subgraph "🔒 Security Metrics"
        SEC1[🚨 Findings Count<br/>- HIGH severity<br/>- MEDIUM severity<br/>- LOW severity<br/>- Trends over time]
        SEC2[🎯 Detection Rate<br/>- True positives<br/>- False positives<br/>- Coverage percentage<br/>- Accuracy metrics]
        SEC3[⚡ Response Time<br/>- Alert to notification<br/>- Time to remediation<br/>- Incident resolution<br/>- SLA compliance]
    end
    
    subgraph "📊 Compliance Metrics"
        COMP1[✅ Compliance Score<br/>- Overall percentage<br/>- Policy adherence<br/>- Risk reduction<br/>- Audit readiness]
        COMP2[📋 Audit Trail<br/>- Access logs<br/>- Change tracking<br/>- Data lineage<br/>- Retention compliance]
        COMP3[🎯 Coverage<br/>- Files scanned %<br/>- Data types covered<br/>- Risk areas identified<br/>- Remediation rate]
    end
    
    OP1 --> OP2
    OP2 --> OP3
    SEC1 --> SEC2
    SEC2 --> SEC3
    COMP1 --> COMP2
    COMP2 --> COMP3
    
    OP3 --> SEC1
    SEC3 --> COMP1
```
