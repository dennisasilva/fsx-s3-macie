# Diagrama de Arquitetura - FSx Compliance PoC com Amazon Macie

## 🏗️ Arquitetura Completa da Solução

```mermaid
graph TB
    %% Definir estilos
    classDef userLayer fill:#e3f2fd,stroke:#1976d2,stroke-width:2px
    classDef networkLayer fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef computeLayer fill:#e8f5e8,stroke:#388e3c,stroke-width:2px
    classDef storageLayer fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    classDef securityLayer fill:#ffebee,stroke:#d32f2f,stroke-width:2px
    classDef monitoringLayer fill:#e0f2f1,stroke:#00796b,stroke-width:2px
    classDef notificationLayer fill:#fce4ec,stroke:#c2185b,stroke-width:2px

    %% Camada de Usuários
    subgraph "👥 Camada de Usuários"
        USER[("👤 Usuários Finais<br/>- Funcionários<br/>- Aplicações<br/>- Sistemas")]
        ADMIN[("👨‍💼 Administradores<br/>- Security Team<br/>- Compliance Team<br/>- IT Operations")]
    end

    %% Camada de Rede
    subgraph "🌐 Infraestrutura de Rede"
        subgraph "VPC (10.0.0.0/16)"
            subgraph "Public Subnet (10.0.2.0/24)"
                IGW["🌐 Internet Gateway"]
                NAT["🔄 NAT Gateway"]
                EIP["📍 Elastic IP"]
            end
            
            subgraph "Private Subnet (10.0.1.0/24)"
                EC2["💻 Windows EC2<br/>t3.medium<br/>- PowerShell Scripts<br/>- Auto Configuration<br/>- SSM Agent"]
                FSX[("🗂️ FSx for Windows<br/>32GB SSD<br/>- SMB/CIFS<br/>- Active Directory<br/>- Automatic Backups")]
                AD["🏢 Managed AD<br/>- Domain Controller<br/>- User Authentication<br/>- Group Policies"]
            end
            
            subgraph "VPC Endpoints"
                VPC_S3["🔗 S3 Gateway Endpoint"]
                VPC_SSM["🔗 SSM Interface Endpoint"]
                VPC_LAMBDA["🔗 Lambda Interface Endpoint"]
                VPC_EVENTS["🔗 EventBridge Interface Endpoint"]
            end
        end
        
        subgraph "Security Groups"
            SG_FSX["🛡️ FSx Security Group<br/>- Port 445 (SMB)<br/>- Port 135 (RPC)<br/>- Dynamic RPC ports"]
            SG_EC2["🛡️ EC2 Security Group<br/>- Port 443 (HTTPS)<br/>- Port 80 (HTTP)<br/>- No RDP (3389)"]
            SG_VPC["🛡️ VPC Endpoint SG<br/>- Port 443 (HTTPS)"]
        end
    end

    %% Camada de Armazenamento
    subgraph "💾 Camada de Armazenamento"
        S3[("📦 S3 Compliance Bucket<br/>- Versioning Enabled<br/>- AES-256 Encryption<br/>- Lifecycle Policies<br/>- Event Notifications")]
        
        subgraph "S3 Structure"
            S3_SYNC["📁 /fsx-sync/<br/>- Arquivos sincronizados<br/>- Metadados preservados<br/>- Estrutura de diretórios"]
            S3_LOGS["📁 /logs/<br/>- Sync logs<br/>- Error logs<br/>- Audit trails"]
        end
    end

    %% Camada de Processamento
    subgraph "⚡ Camada de Processamento"
        LAMBDA1["🚀 Trigger Lambda<br/>- S3 Event Processing<br/>- Macie Job Creation<br/>- File Type Filtering<br/>- Metadata Tagging"]
        
        LAMBDA2["🚀 Findings Lambda<br/>- EventBridge Processing<br/>- Severity Classification<br/>- Alert Generation<br/>- Response Actions"]
        
        SCHEDULER["⏰ EventBridge Scheduler<br/>- Daily Sync Jobs<br/>- Periodic Scans<br/>- Maintenance Tasks"]
    end

    %% Camada de Segurança e Compliance
    subgraph "🔍 Camada de Segurança e Compliance"
        MACIE["🔍 Amazon Macie<br/>- Data Discovery<br/>- PII Detection<br/>- Custom Identifiers<br/>- ML Classification"]
        
        subgraph "Macie Components"
            MACIE_JOBS["⚙️ Classification Jobs<br/>- Scheduled Jobs<br/>- One-time Jobs<br/>- Custom Rules"]
            MACIE_FINDINGS["📊 Findings Database<br/>- Severity Scores<br/>- Data Types<br/>- Risk Assessment"]
            MACIE_CUSTOM["🎯 Custom Identifiers<br/>- CONFIDENCIAL<br/>- RESTRITO<br/>- SIGILOSO<br/>- Regex Patterns"]
        end
        
        CONFIG["⚙️ AWS Config<br/>- Compliance Rules<br/>- Resource Tracking<br/>- Remediation Actions"]
        
        TRAIL["📋 CloudTrail<br/>- API Logging<br/>- Access Audit<br/>- Compliance Trail"]
    end

    %% Camada de Monitoramento
    subgraph "📊 Camada de Monitoramento"
        CW["📈 CloudWatch<br/>- Metrics Collection<br/>- Log Aggregation<br/>- Custom Dashboards"]
        
        subgraph "CloudWatch Components"
            CW_LOGS["📝 CloudWatch Logs<br/>- Lambda Logs<br/>- EC2 Logs<br/>- Application Logs"]
            CW_METRICS["📊 CloudWatch Metrics<br/>- File Count<br/>- Scan Results<br/>- Error Rates"]
            CW_ALARMS["🚨 CloudWatch Alarms<br/>- Threshold Alerts<br/>- Anomaly Detection<br/>- Auto Scaling"]
        end
        
        XRAY["🔍 X-Ray Tracing<br/>- Request Tracing<br/>- Performance Analysis<br/>- Error Tracking"]
    end

    %% Camada de Notificações
    subgraph "📨 Camada de Notificações e Alertas"
        EB["📡 EventBridge<br/>- Event Routing<br/>- Pattern Matching<br/>- Multi-target Delivery"]
        
        SNS["📧 SNS Topics<br/>- Email Notifications<br/>- SMS Alerts<br/>- Slack Integration"]
        
        SQS["📥 SQS Queues<br/>- Message Buffering<br/>- Dead Letter Queues<br/>- Retry Logic"]
        
        subgraph "Notification Types"
            ALERT_HIGH["🚨 High Severity<br/>- Immediate Email<br/>- SMS Alert<br/>- Slack Notification"]
            ALERT_MED["⚠️ Medium Severity<br/>- Email Notification<br/>- Daily Summary"]
            ALERT_LOW["ℹ️ Low Severity<br/>- Weekly Report<br/>- Dashboard Update"]
        end
    end

    %% Camada de Visualização
    subgraph "📊 Camada de Visualização e Relatórios"
        QS["📊 QuickSight<br/>- Compliance Dashboards<br/>- Trend Analysis<br/>- Executive Reports<br/>- Data Visualization"]
        
        SEC_HUB["🔒 Security Hub<br/>- Centralized Findings<br/>- Compliance Scores<br/>- Remediation Tracking<br/>- Multi-account View"]
        
        subgraph "Dashboard Types"
            DASH_EXEC["👔 Executive Dashboard<br/>- High-level Metrics<br/>- Compliance Status<br/>- Risk Overview"]
            DASH_OPS["🔧 Operations Dashboard<br/>- System Health<br/>- Performance Metrics<br/>- Error Tracking"]
            DASH_SEC["🛡️ Security Dashboard<br/>- Threat Detection<br/>- Vulnerability Status<br/>- Incident Response"]
        end
    end

    %% Fluxos de Dados Principais
    USER --> FSX
    FSX --> EC2
    EC2 --> S3
    S3 --> LAMBDA1
    LAMBDA1 --> MACIE_JOBS
    MACIE --> MACIE_FINDINGS
    MACIE_FINDINGS --> EB
    EB --> LAMBDA2
    LAMBDA2 --> SNS
    LAMBDA2 --> SQS

    %% Fluxos de Monitoramento
    LAMBDA1 --> CW_LOGS
    LAMBDA2 --> CW_LOGS
    EC2 --> CW_LOGS
    MACIE_FINDINGS --> CW_METRICS
    CW_METRICS --> CW_ALARMS
    CW_ALARMS --> SNS

    %% Fluxos de Compliance
    FSX --> CONFIG
    EC2 --> TRAIL
    S3 --> TRAIL
    LAMBDA1 --> TRAIL
    LAMBDA2 --> TRAIL

    %% Fluxos de Visualização
    MACIE_FINDINGS --> SEC_HUB
    CW_METRICS --> QS
    SEC_HUB --> QS
    CONFIG --> SEC_HUB

    %% Fluxos de Rede
    IGW --> NAT
    NAT --> EC2
    EC2 --> VPC_S3
    EC2 --> VPC_SSM
    VPC_S3 --> S3
    VPC_SSM --> EC2

    %% Fluxos de Acesso
    ADMIN --> VPC_SSM
    VPC_SSM --> EC2

    %% Aplicar estilos
    class USER,ADMIN userLayer
    class IGW,NAT,EIP,VPC_S3,VPC_SSM,VPC_LAMBDA,VPC_EVENTS,SG_FSX,SG_EC2,SG_VPC networkLayer
    class EC2,LAMBDA1,LAMBDA2,SCHEDULER computeLayer
    class FSX,S3,S3_SYNC,S3_LOGS,AD storageLayer
    class MACIE,MACIE_JOBS,MACIE_FINDINGS,MACIE_CUSTOM,CONFIG,TRAIL securityLayer
    class CW,CW_LOGS,CW_METRICS,CW_ALARMS,XRAY monitoringLayer
    class EB,SNS,SQS,ALERT_HIGH,ALERT_MED,ALERT_LOW,QS,SEC_HUB,DASH_EXEC,DASH_OPS,DASH_SEC notificationLayer
```

## 🔄 Fluxo de Dados Detalhado

```mermaid
sequenceDiagram
    participant U as 👤 Usuário
    participant F as 🗂️ FSx Windows
    participant E as 💻 EC2 Instance
    participant S as 📦 S3 Bucket
    participant L1 as ⚡ Trigger Lambda
    participant M as 🔍 Amazon Macie
    participant L2 as ⚡ Process Lambda
    participant N as 📧 SNS
    participant A as 👨‍💼 Admin

    Note over U,A: Fluxo Completo de Compliance

    U->>F: 1. Salva documento com dados sensíveis
    Note right of F: Arquivo: contrato_cliente.pdf<br/>Conteúdo: CPF, dados bancários

    F->>E: 2. PowerShell detecta novo arquivo
    Note right of E: FileSystemWatcher<br/>monitora mudanças em tempo real

    E->>S: 3. Sincroniza arquivo para S3
    Note right of S: Bucket: fsx-compliance-bucket<br/>Path: /fsx-sync/contratos/

    S->>L1: 4. S3 Event Notification
    Note right of L1: ObjectCreated:Put<br/>Filtro: extensões suportadas

    L1->>M: 5. Cria Classification Job
    Note right of M: Job Type: ONE_TIME<br/>Custom Identifiers: CPF, CONFIDENCIAL

    M->>S: 6. Escaneia conteúdo do arquivo
    Note right of M: ML Analysis + Pattern Matching<br/>Detecta: CPF, dados bancários

    M->>L2: 7. Publica Finding via EventBridge
    Note right of L2: Severity: HIGH (8.5/10)<br/>Type: PII_FINANCIAL

    L2->>S: 8. Adiciona tags de compliance
    Note right of S: Tags: ComplianceStatus=FLAGGED<br/>SeverityLevel=HIGH

    L2->>N: 9. Envia alerta de alta severidade
    Note right of N: Email + SMS + Slack<br/>Notificação imediata

    N->>A: 10. Admin recebe alerta
    Note right of A: "CRÍTICO: Dados bancários<br/>detectados em contrato_cliente.pdf"

    A->>E: 11. Acessa via Session Manager (se necessário)
    Note right of E: aws ssm start-session<br/>Sem necessidade de key-pair

    Note over U,A: Processo automatizado completo<br/>Tempo total: ~5-10 minutos
```

## 🔒 Arquitetura de Segurança

```mermaid
graph LR
    subgraph "🛡️ Camadas de Segurança"
        subgraph "Network Security"
            A1["🌐 VPC Isolation<br/>- Private Subnets<br/>- Security Groups<br/>- NACLs"]
            A2["🔗 VPC Endpoints<br/>- Private Connectivity<br/>- No Internet Routing<br/>- Encrypted Transit"]
        end
        
        subgraph "Identity & Access"
            B1["👤 IAM Roles<br/>- Least Privilege<br/>- Temporary Credentials<br/>- No Long-term Keys"]
            B2["🔐 Session Manager<br/>- No SSH/RDP<br/>- Audit Logging<br/>- MFA Support"]
        end
        
        subgraph "Data Protection"
            C1["🔒 Encryption at Rest<br/>- FSx: AES-256<br/>- S3: AES-256<br/>- EBS: Encrypted"]
            C2["🔐 Encryption in Transit<br/>- TLS 1.2+<br/>- HTTPS Only<br/>- SMB 3.0+"]
        end
        
        subgraph "Monitoring & Compliance"
            D1["📋 CloudTrail<br/>- All API Calls<br/>- Data Events<br/>- Integrity Validation"]
            D2["⚙️ Config Rules<br/>- Compliance Monitoring<br/>- Auto Remediation<br/>- Change Tracking"]
        end
    end
    
    A1 --> A2
    B1 --> B2
    C1 --> C2
    D1 --> D2
    
    A2 --> B1
    B2 --> C1
    C2 --> D1
```

## 📊 Matriz de Responsabilidades

```mermaid
graph TD
    subgraph "🏗️ Componentes AWS"
        COMP1["🗂️ FSx for Windows<br/>- File Storage<br/>- Access Control<br/>- Backup/Restore<br/>- Performance"]
        COMP2["📦 S3<br/>- Object Storage<br/>- Versioning<br/>- Lifecycle<br/>- Cost Optimization"]
        COMP3["🔍 Macie<br/>- Data Discovery<br/>- Classification<br/>- Risk Assessment<br/>- Compliance"]
        COMP4["⚡ Lambda<br/>- Event Processing<br/>- Automation<br/>- Integration<br/>- Scaling"]
        COMP5["📊 Monitoring<br/>- CloudWatch<br/>- Config<br/>- CloudTrail<br/>- Observability"]
    end
    
    subgraph "🎯 Responsabilidades"
        RESP1["🔐 Security<br/>- Encryption<br/>- Access Control<br/>- Compliance<br/>- Audit"]
        RESP2["📈 Performance<br/>- Throughput<br/>- Latency<br/>- Scalability<br/>- Availability"]
        RESP3["💰 Cost<br/>- Storage Optimization<br/>- Compute Efficiency<br/>- Resource Utilization<br/>- Lifecycle Management"]
        RESP4["🔧 Operations<br/>- Monitoring<br/>- Alerting<br/>- Maintenance<br/>- Troubleshooting"]
    end
    
    COMP1 --> RESP1
    COMP1 --> RESP2
    COMP2 --> RESP3
    COMP3 --> RESP1
    COMP4 --> RESP4
    COMP5 --> RESP4
    
    RESP1 --> RESP2
    RESP2 --> RESP3
    RESP3 --> RESP4
```

## 🎯 Cenários de Uso Específicos

```mermaid
flowchart TD
    START([📁 Arquivo adicionado ao FSx]) --> TYPE{🔍 Tipo de arquivo?}
    
    TYPE -->|PDF/DOC/TXT| SYNC[🔄 Sincronização para S3]
    TYPE -->|Outros| IGNORE[❌ Ignorar arquivo]
    
    SYNC --> SCAN[🔍 Macie Analysis]
    
    SCAN --> CLASSIFY{📊 Classificação de Dados}
    
    CLASSIFY -->|PII/Financial| HIGH[🚨 HIGH SEVERITY<br/>- CPF detectado<br/>- Dados bancários<br/>- Informações médicas]
    
    CLASSIFY -->|Keywords| MEDIUM[⚠️ MEDIUM SEVERITY<br/>- CONFIDENCIAL<br/>- RESTRITO<br/>- SIGILOSO]
    
    CLASSIFY -->|Clean| LOW[ℹ️ LOW SEVERITY<br/>- Dados públicos<br/>- Informações gerais]
    
    HIGH --> ACTION_HIGH[🔒 Ações Críticas<br/>- Notificação imediata<br/>- Email + SMS + Slack<br/>- Quarentena do arquivo<br/>- Incident ticket<br/>- Audit log]
    
    MEDIUM --> ACTION_MED[📋 Ações Padrão<br/>- Email notification<br/>- Daily summary<br/>- Compliance review<br/>- Manager notification]
    
    LOW --> ACTION_LOW[📝 Ações Básicas<br/>- Log entry<br/>- Weekly report<br/>- Trend analysis<br/>- Dashboard update]
    
    ACTION_HIGH --> NOTIFY[📨 Multi-channel Alerts]
    ACTION_MED --> NOTIFY
    ACTION_LOW --> REPORT[📊 Reporting & Analytics]
    
    NOTIFY --> REPORT
    
    REPORT --> END([✅ Processo Completo])
    IGNORE --> END
```
