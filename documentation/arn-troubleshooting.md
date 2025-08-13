# Solução de Problemas - ARN do S3 no IAM Role

## 🔧 Problema Persistente

### ❌ **Erro Atual:**
```
Resource handler returned message: "Resource fsx-compliance-poc-compliance-493301683711-us-east-1/* 
must be in ARN format or "*". (Service: Iam, Status Code: 400)
```

## 🔍 **Análise Detalhada**

### **O que está acontecendo:**
1. O CloudFormation está tentando criar um IAM Role
2. A política do role referencia recursos S3
3. O formato do ARN não está sendo aceito pelo IAM

### **Formato Esperado vs Atual:**
```yaml
# ❌ PROBLEMÁTICO (o que pode estar acontecendo):
Resource: "fsx-compliance-poc-compliance-493301683711-us-east-1/*"

# ✅ CORRETO (o que deveria ser):
Resource: "arn:aws:s3:::fsx-compliance-poc-compliance-493301683711-us-east-1/*"
```

## 🛠️ **Correção Definitiva Aplicada**

### **Template Corrigido:**
```yaml
LambdaExecutionRole:
  Type: AWS::IAM::Role
  Properties:
    Policies:
      - PolicyName: MacieAndS3Access
        PolicyDocument:
          Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Action:
                - 's3:GetObject'
                - 's3:GetObjectMetadata'
                - 's3:GetObjectTagging'
                - 's3:PutObjectTagging'
              Resource: !Sub 
                - '${BucketArn}/*'
                - BucketArn: !GetAtt ComplianceBucket.Arn  # ✅ ARN completo
            - Effect: Allow
              Action:
                - 's3:ListBucket'
              Resource: !GetAtt ComplianceBucket.Arn  # ✅ ARN do bucket
```

### **Diferença Chave:**
```yaml
# ANTES (Problemático):
Resource: !Sub '${ComplianceBucket}/*'  # Usa !Ref implicitamente

# DEPOIS (Correto):
Resource: !Sub 
  - '${BucketArn}/*'
  - BucketArn: !GetAtt ComplianceBucket.Arn  # Força uso do ARN
```

## 🚀 **Passos para Resolver**

### **1. Corrigir Stack em ROLLBACK_COMPLETE:**
```bash
# Se a stack está em ROLLBACK_COMPLETE
./fix-rollback-stacks.sh
# Escolher opção 2 (corrigir todas as stacks problemáticas)
# Escolher opção 1 (deletar a stack) quando solicitado
```

### **2. Executar Deploy com Template Corrigido:**
```bash
./deploy-fsx-compliance-poc.sh
# Escolher opção 3 (Deploy FSx e S3)
# Ou opção 1 (Deploy completo)
```

### **3. Verificar se o IAM Role foi Criado:**
```bash
# Verificar se o role existe
aws iam get-role --role-name fsx-compliance-poc-lambda-execution-role

# Verificar a política
aws iam get-role-policy \
    --role-name fsx-compliance-poc-lambda-execution-role \
    --policy-name MacieAndS3Access
```

## 🔍 **Diagnóstico Adicional**

### **Se o Erro Persistir:**

#### **1. Verificar Logs Detalhados:**
```bash
# Ver eventos da stack
aws cloudformation describe-stack-events \
    --stack-name fsx-compliance-poc-storage \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
    --output table
```

#### **2. Verificar Template Localmente:**
```bash
# Validar sintaxe do template
aws cloudformation validate-template \
    --template-body file://fsx-storage.yaml
```

#### **3. Testar Política Isoladamente:**
```bash
# Criar role de teste manualmente
aws iam create-role \
    --role-name test-role \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "lambda.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }'

# Testar política
aws iam put-role-policy \
    --role-name test-role \
    --policy-name test-policy \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": ["s3:GetObject"],
            "Resource": "arn:aws:s3:::fsx-compliance-poc-compliance-493301683711-us-east-1/*"
        }]
    }'
```

## 🔧 **Alternativas de Correção**

### **Opção 1: Usar Wildcard (Menos Seguro)**
```yaml
Resource: "*"  # Permite acesso a todos os buckets S3
```

### **Opção 2: Hardcode do ARN (Para Teste)**
```yaml
Resource: !Sub "arn:aws:s3:::${ComplianceBucket}/*"
```

### **Opção 3: Separar Políticas**
```yaml
# Criar política separada e anexar ao role
ManagedPolicyArns:
  - !Ref S3AccessPolicy

S3AccessPolicy:
  Type: AWS::IAM::ManagedPolicy
  Properties:
    PolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Action: ['s3:GetObject']
          Resource: !Sub '${ComplianceBucket}/*'
```

## 📊 **Validação da Correção**

### **Sinais de Sucesso:**
- ✅ Stack `fsx-compliance-poc-storage` em `CREATE_COMPLETE`
- ✅ IAM Role `fsx-compliance-poc-lambda-execution-role` criado
- ✅ Lambda Function `fsx-compliance-poc-trigger-macie` criada
- ✅ S3 Bucket com notificações configuradas

### **Como Verificar:**
```bash
# Status da stack
aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].StackStatus'

# Role criado
aws iam get-role --role-name fsx-compliance-poc-lambda-execution-role

# Lambda criada
aws lambda get-function --function-name fsx-compliance-poc-trigger-macie
```

## 🎯 **Próximos Passos**

1. **Executar correção** da stack problemática
2. **Deploy com template corrigido**
3. **Verificar criação** dos recursos
4. **Testar funcionamento** da Lambda
5. **Prosseguir** com deploy das outras stacks

## ⚠️ **Se Nada Funcionar**

### **Última Opção - Deploy Simplificado:**
```bash
# Remover todas as stacks
./deploy-fsx-compliance-poc.sh
# Escolher opção 9 (Cleanup)

# Aguardar 10 minutos

# Deploy apenas da infraestrutura principal
./deploy-fsx-compliance-poc.sh
# Escolher opção 2 (Deploy infraestrutura principal)

# Depois tentar storage novamente
# Escolher opção 3 (Deploy FSx e S3)
```

A correção aplicada deve resolver o problema do ARN. Se persistir, pode ser um problema temporário da AWS ou limitação da região. 🚀
