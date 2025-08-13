#!/bin/bash

# Script para Corrigir Stacks em ROLLBACK_COMPLETE
# FSx Compliance PoC - Ferramenta de Correção Rápida

set -e

# Configurações
PROJECT_NAME="fsx-compliance-poc"
REGION="us-east-1"

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

# Função para verificar status da stack
get_stack_status() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_FOUND"
}

# Função para obter detalhes do erro da stack
get_stack_failure_reason() {
    local stack_name=$1
    
    echo ""
    info "Obtendo detalhes do erro para $stack_name..."
    
    # Obter eventos da stack
    local events=$(aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output table 2>/dev/null)
    
    if [ ! -z "$events" ]; then
        echo "Eventos de falha encontrados:"
        echo "$events"
    else
        warning "Nenhum evento de falha específico encontrado"
    fi
    
    # Obter recursos que falharam
    local failed_resources=$(aws cloudformation list-stack-resources \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'StackResourceSummaries[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]' \
        --output table 2>/dev/null)
    
    if [ ! -z "$failed_resources" ]; then
        echo ""
        echo "Recursos que falharam:"
        echo "$failed_resources"
    fi
}

# Função para deletar stack com confirmação
delete_stack_with_confirmation() {
    local stack_name=$1
    local status=$2
    
    echo ""
    critical "Stack: $stack_name"
    critical "Status: $status"
    echo ""
    
    # Mostrar detalhes do erro se disponível
    if [ "$status" = "ROLLBACK_COMPLETE" ] || [ "$status" = "CREATE_FAILED" ]; then
        get_stack_failure_reason "$stack_name"
    fi
    
    echo ""
    warning "Para corrigir esta stack, ela precisa ser deletada e recriada."
    echo ""
    echo "Opções:"
    echo "1. Deletar esta stack"
    echo "2. Pular esta stack"
    echo "3. Sair do script"
    echo ""
    read -p "Escolha uma opção (1/2/3): " choice
    
    case $choice in
        1)
            log "Deletando stack $stack_name..."
            
            if aws cloudformation delete-stack \
                --stack-name "$stack_name" \
                --region "$REGION"; then
                
                log "Comando de deleção enviado. Aguardando conclusão..."
                
                # Aguardar deleção com timeout
                local timeout=1800  # 30 minutos
                local elapsed=0
                local interval=30
                
                while [ $elapsed -lt $timeout ]; do
                    local current_status=$(get_stack_status "$stack_name")
                    
                    if [ "$current_status" = "NOT_FOUND" ]; then
                        success "Stack $stack_name deletada com sucesso!"
                        return 0
                    elif [ "$current_status" = "DELETE_FAILED" ]; then
                        error "Falha na deleção da stack $stack_name"
                        get_stack_failure_reason "$stack_name"
                        return 1
                    else
                        info "Status atual: $current_status (aguardando...)"
                        sleep $interval
                        elapsed=$((elapsed + interval))
                    fi
                done
                
                error "Timeout na deleção da stack $stack_name"
                return 1
            else
                error "Falha ao enviar comando de deleção para $stack_name"
                return 1
            fi
            ;;
        2)
            info "Pulando stack $stack_name"
            return 0
            ;;
        3)
            info "Saindo do script"
            exit 0
            ;;
        *)
            error "Opção inválida"
            return 1
            ;;
    esac
}

# Função principal para verificar e corrigir stacks
check_and_fix_all_stacks() {
    log "Verificando todas as stacks do projeto..."
    
    local stacks=(
        "${PROJECT_NAME}-main"
        "${PROJECT_NAME}-storage"
        "${PROJECT_NAME}-macie"
        "${PROJECT_NAME}-windows"
    )
    
    local problematic_stacks=()
    local fixed_stacks=()
    local skipped_stacks=()
    
    # Primeiro, identificar stacks problemáticas
    echo ""
    info "=== IDENTIFICANDO STACKS PROBLEMÁTICAS ==="
    echo ""
    
    for stack in "${stacks[@]}"; do
        local status=$(get_stack_status "$stack")
        
        case $status in
            "ROLLBACK_COMPLETE"|"CREATE_FAILED"|"UPDATE_FAILED")
                warning "Stack problemática: $stack ($status)"
                problematic_stacks+=("$stack:$status")
                ;;
            "DELETE_FAILED")
                error "Stack com falha na deleção: $stack ($status)"
                problematic_stacks+=("$stack:$status")
                ;;
            "NOT_FOUND")
                info "Stack não existe: $stack (OK)"
                ;;
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                success "Stack funcionando: $stack ($status)"
                ;;
            *)
                info "Stack em estado: $stack ($status)"
                ;;
        esac
    done
    
    # Se não há stacks problemáticas
    if [ ${#problematic_stacks[@]} -eq 0 ]; then
        success "Nenhuma stack problemática encontrada!"
        return 0
    fi
    
    # Processar stacks problemáticas
    echo ""
    info "=== CORRIGINDO STACKS PROBLEMÁTICAS ==="
    echo ""
    
    for stack_info in "${problematic_stacks[@]}"; do
        local stack_name=$(echo "$stack_info" | cut -d':' -f1)
        local stack_status=$(echo "$stack_info" | cut -d':' -f2)
        
        if delete_stack_with_confirmation "$stack_name" "$stack_status"; then
            fixed_stacks+=("$stack_name")
        else
            skipped_stacks+=("$stack_name")
        fi
    done
    
    # Resumo final
    echo ""
    info "=== RESUMO DA CORREÇÃO ==="
    echo ""
    
    if [ ${#fixed_stacks[@]} -gt 0 ]; then
        success "Stacks corrigidas (${#fixed_stacks[@]}):"
        for stack in "${fixed_stacks[@]}"; do
            echo "  ✅ $stack"
        done
    fi
    
    if [ ${#skipped_stacks[@]} -gt 0 ]; then
        warning "Stacks puladas (${#skipped_stacks[@]}):"
        for stack in "${skipped_stacks[@]}"; do
            echo "  ⏭️ $stack"
        done
    fi
    
    echo ""
    if [ ${#fixed_stacks[@]} -gt 0 ]; then
        success "Correção concluída! Você pode agora executar o deploy normalmente."
        info "Execute: ./deploy-fsx-compliance-poc.sh"
    else
        warning "Nenhuma stack foi corrigida."
    fi
}

# Função para mostrar status atual
show_current_status() {
    log "Status atual das stacks:"
    
    local stacks=(
        "${PROJECT_NAME}-main"
        "${PROJECT_NAME}-storage"
        "${PROJECT_NAME}-macie"
        "${PROJECT_NAME}-windows"
    )
    
    echo ""
    printf "%-30s %-25s\n" "STACK NAME" "STATUS"
    printf "%-30s %-25s\n" "----------" "------"
    
    for stack in "${stacks[@]}"; do
        local status=$(get_stack_status "$stack")
        
        case $status in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                printf "%-30s ${GREEN}%-25s${NC}\n" "$stack" "$status"
                ;;
            "ROLLBACK_COMPLETE"|"CREATE_FAILED"|"UPDATE_FAILED"|"DELETE_FAILED")
                printf "%-30s ${RED}%-25s${NC}\n" "$stack" "$status"
                ;;
            "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS"|"DELETE_IN_PROGRESS")
                printf "%-30s ${YELLOW}%-25s${NC}\n" "$stack" "$status"
                ;;
            "NOT_FOUND")
                printf "%-30s ${CYAN}%-25s${NC}\n" "$stack" "$status"
                ;;
            *)
                printf "%-30s ${YELLOW}%-25s${NC}\n" "$stack" "$status"
                ;;
        esac
    done
    echo ""
}

# Menu principal
show_menu() {
    echo ""
    echo "=== Correção de Stacks em ROLLBACK_COMPLETE ==="
    echo "FSx Compliance PoC - Ferramenta de Correção"
    echo ""
    echo "1. Verificar status atual das stacks"
    echo "2. Corrigir todas as stacks problemáticas"
    echo "3. Sair"
    echo ""
    read -p "Escolha uma opção: " choice
}

# Função principal
main() {
    log "Ferramenta de Correção de Stacks - FSx Compliance PoC"
    
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
    
    info "Região: $REGION"
    info "Projeto: $PROJECT_NAME"
    
    while true; do
        show_menu
        
        case $choice in
            1)
                show_current_status
                ;;
            2)
                check_and_fix_all_stacks
                ;;
            3)
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
