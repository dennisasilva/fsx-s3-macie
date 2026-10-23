#!/bin/bash

# Script de Deploy para FSx Compliance PoC - SEM KEY PAIR
# Esta versão usa AWS Systems Manager Session Manager em vez de RDP
# Versão otimizada com cache de email e tratamento de ROLLBACK_COMPLETE
#
# TIMEOUTS CONFIGURADOS:
# - CloudFormation Deploy: 1h 20min (4800s) read + 5 minutos (300s) connect
# - CloudFormation Wait: 1h 20min (4800s) para aguardar conclusão das stacks

set -e

# Definir diretório base do projeto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOUDFORMATION_DIR="$PROJECT_ROOT/cloudformation"
CONFIG_DIR="$PROJECT_ROOT/config"

# Configurações
PROJECT_NAME="fsx-compliance-poc"
REGION="us-east-1"
NOTIFICATION_EMAIL=""

# Arquivo para cache de configurações
CONFIG_FILE="$CONFIG_DIR/.fsx-compliance-config"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Função para logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

critical() {
    echo -e "${CYAN}[CRITICAL]${NC} $1"
}

# Função para salvar configurações
save_config() {
    # Criar com permissões restritivas (apenas o dono pode ler/escrever).
    local _old_umask
    _old_umask=$(umask)
    umask 077
    cat > "$CONFIG_FILE" << EOF
# FSx Compliance PoC - Configurações Salvas
# Gerado automaticamente em $(date)
NOTIFICATION_EMAIL="$NOTIFICATION_EMAIL"
REGION="$REGION"
PROJECT_NAME="$PROJECT_NAME"
LAST_DEPLOY=$(date +%s)
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    umask "$_old_umask"
    success "Configurações salvas em $CONFIG_FILE"
}

# Função para carregar configurações
#
# IMPORTANTE: NÃO usar `source` em um arquivo de dados. O cache é tratado
# como dados puros: só chaves conhecidas são aceitas e cada valor passa
# por validação antes de ser atribuído. Isso elimina execução arbitrária
# de código caso o arquivo seja alterado por outro usuário local ou por
# um commit malicioso.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        info "Nenhuma configuração salva encontrada"
        return 1
    fi

    # Recusar o arquivo se não for do usuário atual ou se estiver com
    # permissões de escrita para grupo/outros (impede plantio por terceiros).
    if [ ! -O "$CONFIG_FILE" ]; then
        warning "Ignorando $CONFIG_FILE: arquivo não pertence ao usuário atual (uid=$(id -u))"
        return 1
    fi
    local _cfg_perms
    _cfg_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$_cfg_perms" ] && [ "${#_cfg_perms}" -ge 3 ]; then
        local _group_bits=${_cfg_perms: -2:1}
        local _other_bits=${_cfg_perms: -1}
        if [ "$((_group_bits & 2))" -ne 0 ] || [ "$((_other_bits & 2))" -ne 0 ]; then
            warning "Ignorando $CONFIG_FILE: permissões $_cfg_perms permitem escrita por grupo/outros"
            return 1
        fi
    fi

    # Leitor explícito key=value com allow-list. Nunca interpreta o arquivo
    # como shell script; valores entre aspas duplas são aceitos literalmente.
    local _k _v
    while IFS='=' read -r _k _v || [ -n "$_k" ]; do
        # Pular comentários e linhas em branco
        case "$_k" in
            ''|\#*) continue ;;
        esac
        # Remover aspas duplas/simples envolventes e espaços nas bordas
        _v="${_v#\"}"; _v="${_v%\"}"
        _v="${_v#\'}"; _v="${_v%\'}"
        _v="${_v#"${_v%%[![:space:]]*}"}"
        _v="${_v%"${_v##*[![:space:]]}"}"
        case "$_k" in
            NOTIFICATION_EMAIL)
                # Re-validar com o mesmo regex de e-mail usado na entrada interativa.
                if [[ "$_v" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                    NOTIFICATION_EMAIL="$_v"
                else
                    warning "Ignorando NOTIFICATION_EMAIL inválido em $CONFIG_FILE"
                fi
                ;;
            REGION)
                if [[ "$_v" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
                    REGION="$_v"
                else
                    warning "Ignorando REGION inválido em $CONFIG_FILE"
                fi
                ;;
            PROJECT_NAME)
                if [[ "$_v" =~ ^[A-Za-z][A-Za-z0-9-]{0,63}$ ]]; then
                    PROJECT_NAME="$_v"
                else
                    warning "Ignorando PROJECT_NAME inválido em $CONFIG_FILE"
                fi
                ;;
            LAST_DEPLOY)
                # Apenas informativo; aceitar inteiros.
                if [[ "$_v" =~ ^[0-9]+$ ]]; then
                    LAST_DEPLOY="$_v"
                fi
                ;;
            *)
                # Chave desconhecida: ignorar silenciosamente.
                ;;
        esac
    done < "$CONFIG_FILE"

    info "Configurações carregadas de $CONFIG_FILE"

    # Mostrar configurações carregadas
    if [ ! -z "$NOTIFICATION_EMAIL" ]; then
        info "Email salvo: $NOTIFICATION_EMAIL"
    fi
    if [ ! -z "$REGION" ]; then
        info "Região salva: $REGION"
    fi

    return 0
}

# Função para limpar configurações
clear_config() {
    if [ -f "$CONFIG_FILE" ]; then
        rm "$CONFIG_FILE"
        success "Configurações limpas"
    else
        warning "Nenhuma configuração para limpar"
    fi
}

# Função para verificar status da stack
get_stack_status() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_FOUND"
}

# Função para deletar stack em ROLLBACK_COMPLETE
delete_failed_stack() {
    local stack_name=$1
    
    warning "Stack $stack_name está em estado ROLLBACK_COMPLETE"
    echo ""
    echo "Opções disponíveis:"
    echo "1. Deletar a stack e recriar (recomendado)"
    echo "2. Cancelar operação"
    echo ""
    read -p "Escolha uma opção (1/2): " choice
    
    case $choice in
        1)
            log "Deletando stack $stack_name..."
            aws cloudformation delete-stack \
                --stack-name "$stack_name" \
                --region "$REGION"
            
            log "Aguardando conclusão da deleção..."
            aws cloudformation wait stack-delete-complete \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --cli-read-timeout 4800
            
            success "Stack $stack_name deletada com sucesso!"
            return 0
            ;;
        2)
            info "Operação cancelada pelo usuário"
            return 1
            ;;
        *)
            error "Opção inválida"
            return 1
            ;;
    esac
}

# Função para verificar e tratar estados problemáticos
check_and_fix_stack_state() {
    local stack_name=$1
    local status=$(get_stack_status "$stack_name")
    
    case $status in
        "ROLLBACK_COMPLETE")
            critical "Stack $stack_name em estado ROLLBACK_COMPLETE"
            if delete_failed_stack "$stack_name"; then
                return 0  # Stack deletada, pode prosseguir
            else
                return 1  # Usuário cancelou
            fi
            ;;
        "ROLLBACK_IN_PROGRESS")
            warning "Stack $stack_name em rollback. Aguardando conclusão..."
            aws cloudformation wait stack-rollback-complete \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --cli-read-timeout 4800
            # Após rollback, vai ficar ROLLBACK_COMPLETE, então chama recursivamente
            check_and_fix_stack_state "$stack_name"
            ;;
        "DELETE_IN_PROGRESS")
            info "Stack $stack_name sendo deletada. Aguardando conclusão..."
            aws cloudformation wait stack-delete-complete \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --cli-read-timeout 4800
            return 0
            ;;
        "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS")
            warning "Stack $stack_name em progresso. Aguardando conclusão..."
            # Aguardar conclusão (pode ser sucesso ou falha)
            sleep 30
            check_and_fix_stack_state "$stack_name"
            ;;
        "CREATE_FAILED")
            warning "Stack $stack_name falhou na criação"
            if delete_failed_stack "$stack_name"; then
                return 0
            else
                return 1
            fi
            ;;
        "UPDATE_ROLLBACK_COMPLETE")
            warning "Stack $stack_name teve update com rollback"
            info "Stack pode ser atualizada normalmente"
            return 0
            ;;
        "CREATE_COMPLETE"|"UPDATE_COMPLETE")
            info "Stack $stack_name em estado válido: $status"
            return 0
            ;;
        "NOT_FOUND")
            info "Stack $stack_name não existe (será criada)"
            return 0
            ;;
        *)
            warning "Stack $stack_name em estado desconhecido: $status"
            return 0
            ;;
    esac
}

# Verificar pré-requisitos
check_prerequisites() {
    log "Verificando pré-requisitos..."
    
    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI não encontrado. Instale o AWS CLI primeiro."
        exit 1
    fi
    
    # Verificar credenciais AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        error "Credenciais AWS não configuradas. Execute 'aws configure' primeiro."
        exit 1
    fi
    
    # Carregar configurações salvas
    load_config || true
    
    # Verificar se o email foi fornecido ou está salvo
    if [ -z "$NOTIFICATION_EMAIL" ]; then
        echo ""
        info "📧 Configuração de Email para Notificações"
        echo "Este email receberá alertas de compliance em tempo real."
        echo ""
        read -p "Digite o email para notificações de compliance: " NOTIFICATION_EMAIL
        if [ -z "$NOTIFICATION_EMAIL" ]; then
            error "Email é obrigatório para receber notificações."
            exit 1
        fi
        
        # Validar formato do email (básico)
        if [[ ! "$NOTIFICATION_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            error "Formato de email inválido. Por favor, digite um email válido."
            exit 1
        fi
        
        # Perguntar se quer salvar
        echo ""
        read -p "Deseja salvar este email para próximos deploys? (y/N): " save_choice
        if [ "$save_choice" = "y" ] || [ "$save_choice" = "Y" ]; then
            save_config
        fi
    else
        echo ""
        info "📧 Usando email salvo: $NOTIFICATION_EMAIL"
        read -p "Deseja usar este email ou digitar um novo? (usar/novo): " email_choice
        if [ "$email_choice" = "novo" ]; then
            read -p "Digite o novo email: " new_email
            if [ ! -z "$new_email" ]; then
                NOTIFICATION_EMAIL="$new_email"
                # Validar formato do email
                if [[ ! "$NOTIFICATION_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                    error "Formato de email inválido."
                    exit 1
                fi
                save_config
            fi
        fi
    fi
    
    success "Pré-requisitos verificados com sucesso!"
    warning "Esta versão usa AWS Systems Manager Session Manager (sem key-pair)"
}

# Função para fazer deploy de uma stack com tratamento de erros
deploy_stack() {
    local stack_name=$1
    local template_file=$2
    shift 2
    # Cada parameter-override é um argumento posicional separado,
    # evitando word-splitting de valores vindos de configuração.
    local parameters=("$@")
    
    log "Fazendo deploy da stack: $stack_name"
    
    # Verificar se template existe
    if [ ! -f "$template_file" ]; then
        error "Template não encontrado: $template_file"
        return 1
    fi
    
    # Verificar e corrigir estado da stack
    if ! check_and_fix_stack_state "$stack_name"; then
        error "Não foi possível corrigir o estado da stack $stack_name"
        return 1
    fi
    
    # Mostrar parâmetros que serão usados
    info "Parâmetros: ${parameters[*]}"
    
    # Tentar deploy com retry
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "Tentativa $attempt/$max_attempts para deploy de $stack_name"
        
        if aws cloudformation deploy \
            --template-file "$template_file" \
            --stack-name "$stack_name" \
            --parameter-overrides "${parameters[@]}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" \
            --no-fail-on-empty-changeset \
            --cli-read-timeout 4800 \
            --cli-connect-timeout 300; then
            
            success "Stack $stack_name deployada com sucesso!"
            return 0
        else
            local exit_code=$?
            warning "Tentativa $attempt falhou (exit code: $exit_code)"
            
            # Verificar se a stack ficou em estado problemático
            local current_status=$(get_stack_status "$stack_name")
            if [ "$current_status" = "ROLLBACK_COMPLETE" ] || [ "$current_status" = "CREATE_FAILED" ]; then
                warning "Stack ficou em estado problemático: $current_status"
                if [ $attempt -lt $max_attempts ]; then
                    if check_and_fix_stack_state "$stack_name"; then
                        attempt=$((attempt + 1))
                        continue
                    else
                        break
                    fi
                fi
            fi
            
            attempt=$((attempt + 1))
            if [ $attempt -le $max_attempts ]; then
                warning "Aguardando 30 segundos antes da próxima tentativa..."
                sleep 30
            fi
        fi
    done
    
    error "Falha no deploy da stack $stack_name após $max_attempts tentativas"
    return 1
}

# Deploy da infraestrutura principal
deploy_main_infrastructure() {
    log "Iniciando deploy da infraestrutura principal..."
    
    deploy_stack \
        "${PROJECT_NAME}-main" \
        "$CLOUDFORMATION_DIR/fsx-compliance-main.yaml" \
        "ProjectName=$PROJECT_NAME" \
        "NotificationEmail=$NOTIFICATION_EMAIL"
}

# Deploy do FSx e S3
deploy_storage() {
    log "Iniciando deploy do FSx e S3..."
    
    deploy_stack \
        "${PROJECT_NAME}-storage" \
        "$CLOUDFORMATION_DIR/fsx-storage.yaml" \
        "MainStackName=${PROJECT_NAME}-main" \
        "FSxStorageCapacity=32"
}

# Deploy do Macie e processamento
deploy_macie() {
    log "Iniciando deploy do Macie e processamento..."
    
    deploy_stack \
        "${PROJECT_NAME}-macie" \
        "$CLOUDFORMATION_DIR/macie-processing.yaml" \
        "MainStackName=${PROJECT_NAME}-main" \
        "StorageStackName=${PROJECT_NAME}-storage"
}

# Deploy do cliente Windows (SEM KEY PAIR)
deploy_windows_client() {
    log "Iniciando deploy do cliente Windows (SEM key-pair)..."
    
    deploy_stack \
        "${PROJECT_NAME}-windows" \
        "$CLOUDFORMATION_DIR/windows-client.yaml" \
        "MainStackName=${PROJECT_NAME}-main" \
        "StorageStackName=${PROJECT_NAME}-storage" \
        "InstanceType=t3.medium"
}

# Verificar status das stacks
check_stack_status() {
    log "Verificando status das stacks..."
    
    local stacks=(
        "${PROJECT_NAME}-main"
        "${PROJECT_NAME}-storage"
        "${PROJECT_NAME}-macie"
        "${PROJECT_NAME}-windows"
    )
    
    echo ""
    printf "%-30s %-25s %-30s\n" "STACK NAME" "STATUS" "LAST UPDATED"
    printf "%-30s %-25s %-30s\n" "----------" "------" "------------"
    
    for stack in "${stacks[@]}"; do
        local status=$(get_stack_status "$stack")
        local last_updated=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" --query 'Stacks[0].LastUpdatedTime' --output text 2>/dev/null || echo "N/A")
        
        case $status in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                printf "%-30s ${GREEN}%-25s${NC} %-30s\n" "$stack" "$status" "$last_updated"
                ;;
            "ROLLBACK_COMPLETE"|"CREATE_FAILED"|"UPDATE_FAILED")
                printf "%-30s ${RED}%-25s${NC} %-30s\n" "$stack" "$status" "$last_updated"
                ;;
            "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS"|"DELETE_IN_PROGRESS")
                printf "%-30s ${YELLOW}%-25s${NC} %-30s\n" "$stack" "$status" "$last_updated"
                ;;
            "NOT_FOUND")
                printf "%-30s ${CYAN}%-25s${NC} %-30s\n" "$stack" "$status" "$last_updated"
                ;;
            *)
                printf "%-30s ${YELLOW}%-25s${NC} %-30s\n" "$stack" "$status" "$last_updated"
                ;;
        esac
    done
    echo ""
    
    # Mostrar legend
    echo "Legenda:"
    echo -e "  ${GREEN}Verde${NC}: Stack funcionando corretamente"
    echo -e "  ${RED}Vermelho${NC}: Stack com problemas (pode precisar ser deletada)"
    echo -e "  ${YELLOW}Amarelo${NC}: Stack em progresso ou estado transitório"
    echo -e "  ${CYAN}Ciano${NC}: Stack não existe"
}

# Função para cleanup com tratamento de estados
cleanup() {
    log "Iniciando cleanup da infraestrutura..."
    
    local stacks=(
        "${PROJECT_NAME}-windows"
        "${PROJECT_NAME}-macie"
        "${PROJECT_NAME}-storage"
        "${PROJECT_NAME}-main"
    )
    
    echo ""
    warning "⚠️  ATENÇÃO: Esta operação irá REMOVER TODA a infraestrutura!"
    echo ""
    echo "Stacks que serão removidas:"
    for stack in "${stacks[@]}"; do
        local status=$(get_stack_status "$stack")
        echo "  - $stack ($status)"
    done
    echo ""
    read -p "Digite 'DELETE' para confirmar a remoção: " confirm
    
    if [ "$confirm" = "DELETE" ]; then
        for stack in "${stacks[@]}"; do
            local status=$(get_stack_status "$stack")
            
            if [ "$status" != "NOT_FOUND" ]; then
                log "Removendo stack: $stack (status: $status)"
                
                # Se stack está em ROLLBACK_COMPLETE, pode deletar diretamente
                aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"
                
                # Aguardar deleção se não for a última stack
                if [ "$stack" != "${PROJECT_NAME}-main" ]; then
                    log "Aguardando deleção de $stack..."
                    aws cloudformation wait stack-delete-complete \
                        --stack-name "$stack" \
                        --region "$REGION" \
                        --cli-read-timeout 4800 || true
                fi
            else
                info "Stack $stack não existe, pulando..."
            fi
        done
        
        warning "Cleanup iniciado. Aguardando conclusão da última stack..."
        aws cloudformation wait stack-delete-complete \
            --stack-name "${PROJECT_NAME}-main" \
            --region "$REGION" \
            --cli-read-timeout 4800 || true
        
        success "Cleanup concluído!"
    else
        info "Cleanup cancelado."
    fi
}

# Função para corrigir stacks problemáticas
fix_problematic_stacks() {
    log "Verificando e corrigindo stacks problemáticas..."
    
    local stacks=(
        "${PROJECT_NAME}-main"
        "${PROJECT_NAME}-storage"
        "${PROJECT_NAME}-macie"
        "${PROJECT_NAME}-windows"
    )
    
    local fixed_count=0
    
    for stack in "${stacks[@]}"; do
        local status=$(get_stack_status "$stack")
        
        case $status in
            "ROLLBACK_COMPLETE"|"CREATE_FAILED")
                warning "Stack problemática encontrada: $stack ($status)"
                if check_and_fix_stack_state "$stack"; then
                    fixed_count=$((fixed_count + 1))
                    success "Stack $stack corrigida"
                else
                    error "Não foi possível corrigir $stack"
                fi
                ;;
            "NOT_FOUND")
                info "Stack $stack não existe (OK)"
                ;;
            *)
                info "Stack $stack em estado válido: $status"
                ;;
        esac
    done
    
    if [ $fixed_count -gt 0 ]; then
        success "$fixed_count stack(s) corrigida(s)"
    else
        info "Nenhuma stack problemática encontrada"
    fi
}

# Obter outputs importantes (função existente mantida)
get_outputs() {
    log "Obtendo informações importantes da infraestrutura..."
    
    echo ""
    echo "=== INFORMAÇÕES DA INFRAESTRUTURA ==="
    echo ""
    
    # FSx DNS Name
    local fsx_dns=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-storage" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`FSxDNSName`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    echo "FSx DNS Name: $fsx_dns"
    
    # S3 Bucket
    local s3_bucket=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-storage" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketName`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    echo "S3 Compliance Bucket: $s3_bucket"
    
    # Windows Instance IP
    local windows_ip=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-windows" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`WindowsInstancePrivateIP`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    echo "Windows Instance IP: $windows_ip"
    
    # Windows Instance ID
    local instance_id=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-windows" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`WindowsInstanceId`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    echo "Windows Instance ID: $instance_id"
    
    # SNS Topic
    local sns_topic=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-macie" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ComplianceAlertsTopicArn`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    echo "SNS Topic ARN: $sns_topic"
    
    echo ""
    echo "=== ACESSO À INSTÂNCIA WINDOWS (SEM KEY-PAIR) ==="
    echo ""
    echo "🔧 Para conectar à instância Windows, use AWS Systems Manager:"
    echo ""
    echo "1. Via AWS CLI:"
    echo "   aws ssm start-session --target $instance_id --region $REGION"
    echo ""
    echo "2. Via Console AWS:"
    echo "   - Acesse EC2 Console"
    echo "   - Selecione a instância: $instance_id"
    echo "   - Clique em 'Connect' → 'Session Manager'"
    echo ""
    echo "3. Para PowerShell na instância:"
    echo "   aws ssm start-session --target $instance_id --region $REGION --document-name AWS-StartPowerShellSession"
    echo ""
    
    echo "=== FUNCIONAMENTO AUTOMATIZADO ==="
    echo ""
    echo "✅ A solução funciona COMPLETAMENTE AUTOMATIZADA:"
    echo ""
    echo "1. 🤖 Instância Windows se configura automaticamente"
    echo "2. 📁 Cria arquivos de teste com dados sensíveis"
    echo "3. 🔄 Sincroniza arquivos FSx → S3 automaticamente"
    echo "4. 🔍 Macie escaneia e detecta dados sensíveis"
    echo "5. 📨 Envia alertas para: $NOTIFICATION_EMAIL"
    echo "6. ⏰ Sincronização agendada diariamente às 02:00"
    echo ""
    echo "=== MONITORAMENTO ==="
    echo ""
    echo "📊 Verifique os seguintes locais:"
    echo "- Email: $NOTIFICATION_EMAIL (alertas de compliance)"
    echo "- S3 Bucket: $s3_bucket"
    echo "- Macie Console: https://console.aws.amazon.com/macie/"
    echo "- CloudWatch Logs: /aws/lambda/fsx-compliance-poc-*"
    echo ""
    echo "⏱️ Aguarde 10-15 minutos após o deploy para ver os primeiros alertas!"
    echo ""
    
    # Salvar informações em arquivo
    cat > "$CONFIG_DIR/deployment-info.txt" << EOF
FSx Compliance PoC - Deployment Information
Generated: $(date)

Infrastructure:
- FSx DNS Name: $fsx_dns
- S3 Bucket: $s3_bucket
- Windows Instance IP: $windows_ip
- Windows Instance ID: $instance_id
- SNS Topic: $sns_topic
- Notification Email: $NOTIFICATION_EMAIL
- Region: $REGION

Access Commands:
- Session Manager: aws ssm start-session --target $instance_id --region $REGION
- PowerShell: aws ssm start-session --target $instance_id --region $REGION --document-name AWS-StartPowerShellSession

Monitoring:
- Macie Console: https://console.aws.amazon.com/macie/
- S3 Console: https://s3.console.aws.amazon.com/s3/buckets/$s3_bucket
- CloudWatch: https://console.aws.amazon.com/cloudwatch/
EOF
    
    success "Informações salvas em $CONFIG_DIR/deployment-info.txt"
}

# Menu principal
show_menu() {
    echo ""
    echo "=== FSx Compliance PoC - Deploy Script (SEM KEY-PAIR) ==="
    echo ""
    echo "🔧 Esta versão usa AWS Systems Manager Session Manager"
    echo "🤖 Funcionamento completamente automatizado"
    echo "🛠️ Tratamento automático de stacks em ROLLBACK_COMPLETE"
    if [ -f "$CONFIG_FILE" ]; then
        echo "💾 Configurações salvas encontradas"
    fi
    echo ""
    echo "1. Deploy completo (todas as stacks)"
    echo "2. Deploy infraestrutura principal"
    echo "3. Deploy FSx e S3"
    echo "4. Deploy Macie e processamento"
    echo "5. Deploy cliente Windows (automatizado)"
    echo "6. Verificar status das stacks"
    echo "7. Obter informações da infraestrutura"
    echo "8. Corrigir stacks problemáticas"
    echo "9. Cleanup (remover todas as stacks)"
    echo "10. Limpar configurações salvas"
    echo "11. Sair"
    echo ""
    read -p "Escolha uma opção: " choice
}

# Função principal
main() {
    log "Iniciando FSx Compliance PoC Deploy Script (SEM KEY-PAIR)"
    
    # Verificar se os templates existem
    local templates=(
        "$CLOUDFORMATION_DIR/fsx-compliance-main.yaml"
        "$CLOUDFORMATION_DIR/fsx-storage.yaml"
        "$CLOUDFORMATION_DIR/macie-processing.yaml"
        "$CLOUDFORMATION_DIR/windows-client.yaml"
    )
    
    for template in "${templates[@]}"; do
        if [ ! -f "$template" ]; then
            error "Template não encontrado: $template"
            exit 1
        fi
    done
    
    check_prerequisites
    
    while true; do
        show_menu
        
        case $choice in
            1)
                log "Iniciando deploy completo automatizado..."
                deploy_main_infrastructure && \
                deploy_storage && \
                deploy_macie && \
                deploy_windows_client && \
                check_stack_status && \
                get_outputs
                ;;
            2)
                deploy_main_infrastructure
                ;;
            3)
                deploy_storage
                ;;
            4)
                deploy_macie
                ;;
            5)
                deploy_windows_client
                ;;
            6)
                check_stack_status
                ;;
            7)
                get_outputs
                ;;
            8)
                fix_problematic_stacks
                ;;
            9)
                cleanup
                ;;
            10)
                clear_config
                ;;
            11)
                log "Saindo..."
                exit 0
                ;;
            *)
                warning "Opção inválida. Tente novamente."
                ;;
        esac
        
        echo ""
        read -p "Pressione Enter para continuar..."
    done
}

# Executar função principal
main "$@"
