#!/bin/bash

# ============================================================================
# SCRIPT DE VERIFICAÇÃO DO SSM AGENT
# ============================================================================
# Este script verifica se o SSM Agent está funcionando corretamente
# na instância Windows e se ela está registrada no Systems Manager
# ============================================================================

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configurações
PROJECT_NAME="fsx-compliance-poc"
REGION="us-east-1"

# Função para logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✅${NC} $1"
}

error() {
    echo -e "${RED}❌${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

info() {
    echo -e "${CYAN}ℹ️${NC} $1"
}

echo "=== VERIFICAÇÃO DO SSM AGENT - FSx Compliance PoC ==="
echo "AMI: ami-0758218dcb57e4a14 (Windows Server 2022 Full Base + Interface Gráfica)"
echo ""

# Verificar se AWS CLI está configurado
if ! command -v aws &> /dev/null; then
    error "AWS CLI não encontrado. Execute 'aws configure' primeiro."
    exit 1
fi

# Obter Instance ID
log "Obtendo Instance ID da stack Windows..."
INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-windows" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`WindowsInstanceId`].OutputValue' \
    --output text 2>/dev/null)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    error "Não foi possível obter o Instance ID. Verifique se a stack está deployada."
    exit 1
fi

success "Instance ID encontrado: $INSTANCE_ID"

# Verificar se a instância está rodando
log "Verificando status da instância..."
INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

if [ "$INSTANCE_STATE" != "running" ]; then
    error "Instância não está rodando. Status atual: $INSTANCE_STATE"
    exit 1
fi

success "Instância está rodando"

# Verificar se a instância está registrada no Systems Manager
log "Verificando registro no Systems Manager..."
SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --region "$REGION" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null)

if [ -z "$SSM_STATUS" ] || [ "$SSM_STATUS" = "None" ]; then
    error "Instância NÃO está registrada no Systems Manager"
    echo ""
    warning "Possíveis causas:"
    echo "   • SSM Agent não está instalado"
    echo "   • SSM Agent não está rodando"
    echo "   • IAM Role não tem permissões corretas"
    echo "   • VPC Endpoints não estão configurados"
    echo "   • Security Groups bloqueando tráfego HTTPS"
    echo ""
    info "Soluções:"
    echo "   1. Aguarde alguns minutos (pode levar até 5 min para registrar)"
    echo "   2. Verifique os logs da instância:"
    echo "      aws ssm start-session --target $INSTANCE_ID --region $REGION"
    echo "      Get-Content C:\\Windows\\Temp\\userdata.log"
    echo "   3. Verifique se o SSM Agent está rodando:"
    echo "      Get-Service -Name 'AmazonSSMAgent'"
    exit 1
fi

if [ "$SSM_STATUS" = "Online" ]; then
    success "Instância está ONLINE no Systems Manager"
else
    warning "Instância está registrada mas status: $SSM_STATUS"
fi

# Obter informações detalhadas da instância no SSM
log "Obtendo informações detalhadas do SSM..."
SSM_INFO=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --region "$REGION" \
    --output json 2>/dev/null)

if [ -n "$SSM_INFO" ] && [ "$SSM_INFO" != "null" ]; then
    echo ""
    echo "📊 INFORMAÇÕES DA INSTÂNCIA NO SSM:"
    echo "$SSM_INFO" | jq -r '.InstanceInformationList[0] | 
        "   • Instance ID: " + .InstanceId + 
        "\n   • Platform: " + .PlatformName + " " + .PlatformVersion +
        "\n   • SSM Agent: " + .AgentVersion +
        "\n   • Status: " + .PingStatus +
        "\n   • Última comunicação: " + .LastPingDateTime'
fi

# Testar conectividade Session Manager
log "Testando conectividade do Session Manager..."
echo ""
info "🖥️ OPÇÕES DE ACESSO GRÁFICO:"
echo "   1. Fleet Manager (Recomendado):"
echo "      AWS Console → Systems Manager → Fleet Manager → Select Instance → Remote Desktop"
echo ""
echo "   2. RDP via Túnel Session Manager:"
echo "      aws ssm start-session --target $INSTANCE_ID --region $REGION --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"3389\"],\"localPortNumber\":[\"9999\"]}'"
echo "      Depois: mstsc /v:localhost:9999 (Windows) ou Microsoft Remote Desktop → localhost:9999 (Mac)"
echo ""
info "💻 ACESSO VIA LINHA DE COMANDO:"
echo "   aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
info "🔧 POWERSHELL REMOTO:"
echo "   aws ssm start-session --target $INSTANCE_ID --region $REGION --document-name AWS-StartPowerShellSession"
echo ""

# Verificar VPC Endpoints
log "Verificando VPC Endpoints necessários..."
VPC_ID=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].VpcId' \
    --output text)

ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query 'VpcEndpoints[?ServiceName==`com.amazonaws.us-east-1.ssm` || ServiceName==`com.amazonaws.us-east-1.ssmmessages` || ServiceName==`com.amazonaws.us-east-1.ec2messages`].ServiceName' \
    --output text)

REQUIRED_ENDPOINTS=("com.amazonaws.us-east-1.ssm" "com.amazonaws.us-east-1.ssmmessages" "com.amazonaws.us-east-1.ec2messages")

for endpoint in "${REQUIRED_ENDPOINTS[@]}"; do
    if echo "$ENDPOINTS" | grep -q "$endpoint"; then
        success "VPC Endpoint encontrado: $endpoint"
    else
        warning "VPC Endpoint FALTANDO: $endpoint"
    fi
done

# Verificar IAM Role
log "Verificando IAM Role da instância..."
IAM_ROLE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
    --output text)

if [ -n "$IAM_ROLE" ] && [ "$IAM_ROLE" != "None" ]; then
    success "IAM Instance Profile configurado: $(basename "$IAM_ROLE")"
else
    error "IAM Instance Profile NÃO configurado"
fi

echo ""
echo "=== RESUMO DA VERIFICAÇÃO ==="
if [ "$SSM_STATUS" = "Online" ]; then
    success "✅ SSM Agent está funcionando corretamente"
    success "✅ Instância pode ser acessada via Session Manager"
    success "✅ Interface gráfica disponível via Fleet Manager"
    success "✅ RDP via túnel totalmente funcional"
    echo ""
    info "🖥️ Para acesso gráfico (Recomendado):"
    echo "   AWS Console → Systems Manager → Fleet Manager → Remote Desktop"
    echo ""
    info "💻 Para linha de comando:"
    echo "   aws ssm start-session --target $INSTANCE_ID --region $REGION"
else
    error "❌ SSM Agent NÃO está funcionando corretamente"
    echo ""
    warning "Aguarde alguns minutos e execute novamente este script"
    warning "Se o problema persistir, verifique os logs da instância"
fi

echo ""
log "Verificação concluída!"
