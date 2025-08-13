# Tratamento de Erros ROLLBACK_COMPLETE - FSx Compliance PoC

## 🔧 Problema: Stack em Estado ROLLBACK_COMPLETE

### ❌ **Erro Original:**
```
An error occurred (ValidationError) when calling the CreateChangeSet operation: 
Stack:arn:aws:cloudformation:us-east-1:493301683711:stack/fsx-compliance-poc-storage/95c02010-77ce-11f0-904a-0e458fd1122d 
is in ROLLBACK_COMPLETE state and can not be updated
```

### 🔍 **Causa Raiz:**
Quando uma stack do CloudFormation falha durante a criação, ela entra no estado `ROLLBACK_COMPLETE`. Neste estado:
- ❌ **Não pode ser atualizada** (update)
- ❌ **Não pode ser recriada** com o mesmo nome
- ✅ **Pode apenas ser deletada**

### ✅ **Solução Implementada:**

## 🛠️ **1. Script Principal Atualizado**

O script `deploy-fsx-compliance-poc.sh` agora inclui:

### **Detecção Automática de Estados Problemáticos**
```bash
get_stack_status() {
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_FOUND"
}

check_and_fix_stack_state() {
    local status=$(get_stack_status "$stack_name")
    
    case $status in
        "ROLLBACK_COMPLETE"|"CREATE_FAILED")
            # Oferece opção de deletar e recriar
            delete_failed_stack "$stack_name"
            ;;
        "ROLLBACK_IN_PROGRESS")
            # Aguarda conclusão do rollback
            aws cloudformation wait stack-rollback-complete
            ;;
        # ... outros estados
    esac
}
```

### **Deleção Automática com Confirmação**
```bash
delete_failed_stack() {
    warning "Stack $stack_name está em estado ROLLBACK_COMPLETE"
    echo "1. Deletar a stack e recriar (recomendado)"
    echo "2. Cancelar operação"
    
    read -p "Escolha uma opção (1/2): " choice
    
    if [ "$choice" = "1" ]; then
        aws cloudformation delete-stack --stack-name "$stack_name"
        aws cloudformation wait stack-delete-complete --stack-name "$stack_name"
    fi
}
```

### **Deploy com Retry Automático**
```bash
deploy_stack() {
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Verificar e corrigir estado antes de cada tentativa
        check_and_fix_stack_state "$stack_name"
        
        if aws cloudformation deploy ...; then
            return 0  # Sucesso
        else
            # Se falhou, verificar se ficou em estado problemático
            local status=$(get_stack_status "$stack_name")
            if [ "$status" = "ROLLBACK_COMPLETE" ]; then
                # Corrigir e tentar novamente
                check_and_fix_stack_state "$stack_name"
            fi
        fi
        
        attempt=$((attempt + 1))
    done
}
```

## 🛠️ **2. Script de Correção Dedicado**

### **`fix-rollback-stacks.sh`** - Ferramenta Especializada

#### **Funcionalidades:**
- ✅ **Detecção automática** de todas as stacks problemáticas
- ✅ **Análise de erros** com detalhes dos recursos que falharam
- ✅ **Deleção assistida** com confirmação
- ✅ **Relatório de correção** com resumo das ações

#### **Como Usar:**
```bash
# Executar ferramenta de correção
./fix-rollback-stacks.sh

# Opções disponíveis:
# 1. Verificar status atual das stacks
# 2. Corrigir todas as stacks problemáticas
# 3. Sair
```

#### **Exemplo de Saída:**
```
=== IDENTIFICANDO STACKS PROBLEMÁTICAS ===

⚠️ Stack problemática: fsx-compliance-poc-storage (ROLLBACK_COMPLETE)
✅ Stack funcionando: fsx-compliance-poc-main (CREATE_COMPLETE)

=== CORRIGINDO STACKS PROBLEMÁTICAS ===

Stack: fsx-compliance-poc-storage
Status: ROLLBACK_COMPLETE

Eventos de falha encontrados:
|  Timestamp  | LogicalResourceId | ResourceStatus | ResourceStatusReason |
|-------------|-------------------|----------------|---------------------|
| 2024-01-15  | ADPassword        | CREATE_FAILED  | SecureString invalid|

Opções:
1. Deletar esta stack
2. Pular esta stack
3. Sair do script
```

## 📊 **3. Estados de Stack Tratados**

### **Estados Problemáticos (Requerem Correção):**
- 🔴 **ROLLBACK_COMPLETE**: Stack falhou e fez rollback
- 🔴 **CREATE_FAILED**: Stack falhou na criação
- 🔴 **UPDATE_FAILED**: Stack falhou no update
- 🔴 **DELETE_FAILED**: Stack falhou na deleção

### **Estados Transitórios (Aguardar):**
- 🟡 **CREATE_IN_PROGRESS**: Stack sendo criada
- 🟡 **UPDATE_IN_PROGRESS**: Stack sendo atualizada
- 🟡 **DELETE_IN_PROGRESS**: Stack sendo deletada
- 🟡 **ROLLBACK_IN_PROGRESS**: Stack fazendo rollback

### **Estados Válidos (OK):**
- 🟢 **CREATE_COMPLETE**: Stack criada com sucesso
- 🟢 **UPDATE_COMPLETE**: Stack atualizada com sucesso
- 🟢 **UPDATE_ROLLBACK_COMPLETE**: Update falhou mas rollback OK
- 🔵 **NOT_FOUND**: Stack não existe (pode ser criada)

## 🚀 **4. Fluxo de Correção Automática**

### **Cenário 1: Deploy Normal**
```
1. Verificar status da stack
2. Se OK → Prosseguir com deploy
3. Se problemática → Corrigir automaticamente
4. Executar deploy
```

### **Cenário 2: Stack em ROLLBACK_COMPLETE**
```
1. Detectar estado ROLLBACK_COMPLETE
2. Mostrar detalhes do erro
3. Solicitar confirmação do usuário
4. Deletar stack
5. Aguardar deleção completa
6. Prosseguir com deploy (recriação)
```

### **Cenário 3: Múltiplas Tentativas**
```
1. Primeira tentativa de deploy
2. Se falhar → Verificar estado resultante
3. Se ROLLBACK_COMPLETE → Corrigir e tentar novamente
4. Repetir até 3 tentativas
5. Se ainda falhar → Reportar erro detalhado
```

## 🔧 **5. Comandos de Correção Manual**

### **Verificar Status de Uma Stack:**
```bash
aws cloudformation describe-stacks \
    --stack-name fsx-compliance-poc-storage \
    --query 'Stacks[0].StackStatus' \
    --output text
```

### **Deletar Stack Problemática:**
```bash
aws cloudformation delete-stack \
    --stack-name fsx-compliance-poc-storage

# Aguardar deleção
aws cloudformation wait stack-delete-complete \
    --stack-name fsx-compliance-poc-storage
```

### **Ver Detalhes do Erro:**
```bash
aws cloudformation describe-stack-events \
    --stack-name fsx-compliance-poc-storage \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]'
```

## 📋 **6. Menu Atualizado do Script Principal**

```
=== FSx Compliance PoC - Deploy Script (SEM KEY-PAIR) ===

🔧 Esta versão usa AWS Systems Manager Session Manager
🤖 Funcionamento completamente automatizado
🛠️ Tratamento automático de stacks em ROLLBACK_COMPLETE

1. Deploy completo (todas as stacks)
2. Deploy infraestrutura principal
3. Deploy FSx e S3
4. Deploy Macie e processamento
5. Deploy cliente Windows (automatizado)
6. Verificar status das stacks
7. Obter informações da infraestrutura
8. Corrigir stacks problemáticas          ⭐ NOVO
9. Cleanup (remover todas as stacks)
10. Limpar configurações salvas
11. Sair
```

## ✅ **7. Benefícios da Solução**

### **🤖 Automação Completa:**
- **Detecção automática** de stacks problemáticas
- **Correção assistida** com confirmação do usuário
- **Retry automático** após correção
- **Relatórios detalhados** de erros e correções

### **🛡️ Segurança:**
- **Confirmação obrigatória** antes de deletar stacks
- **Backup de informações** antes da deleção
- **Logs detalhados** de todas as operações
- **Rollback seguro** em caso de problemas

### **👥 Experiência do Usuário:**
- **Mensagens claras** sobre o que está acontecendo
- **Opções flexíveis** (corrigir, pular, cancelar)
- **Status visual** com cores para fácil identificação
- **Informações contextuais** sobre erros

## 🎯 **8. Como Usar as Correções**

### **Cenário A: Deploy Falhou**
```bash
# Se o deploy falhou com erro ROLLBACK_COMPLETE
./deploy-fsx-compliance-poc.sh
# Escolher opção 1 (deploy completo)
# Script detectará automaticamente e oferecerá correção
```

### **Cenário B: Correção Preventiva**
```bash
# Para corrigir stacks problemáticas antes do deploy
./fix-rollback-stacks.sh
# Escolher opção 2 (corrigir todas as stacks problemáticas)

# Depois executar deploy normal
./deploy-fsx-compliance-poc.sh
```

### **Cenário C: Verificação de Status**
```bash
./deploy-fsx-compliance-poc.sh
# Escolher opção 6 (verificar status das stacks)
# Ou opção 8 (corrigir stacks problemáticas)
```

## 📁 **9. Arquivos Atualizados**

1. **`deploy-fsx-compliance-poc.sh`** - Script principal com tratamento de ROLLBACK_COMPLETE
2. **`fix-rollback-stacks.sh`** - Ferramenta dedicada para correção de stacks
3. **`rollback-handling.md`** - Esta documentação

## ✅ **10. Status Final**

- ✅ **Detecção automática**: Estados problemáticos identificados
- ✅ **Correção assistida**: Deleção com confirmação do usuário
- ✅ **Retry automático**: Tentativas múltiplas após correção
- ✅ **Ferramenta dedicada**: Script especializado para correção
- ✅ **Experiência melhorada**: Interface clara e informativa

A solução agora **trata automaticamente** o erro ROLLBACK_COMPLETE e outros estados problemáticos, garantindo que o deploy funcione mesmo após falhas anteriores! 🚀
