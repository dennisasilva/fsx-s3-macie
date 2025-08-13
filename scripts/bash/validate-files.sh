#!/bin/bash

# Script de Validação - FSx Compliance PoC
# Verifica se todos os arquivos referenciados existem e estão corretos

set -e

# Definir diretório base do projeto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOUDFORMATION_DIR="$PROJECT_ROOT/cloudformation"
CONFIG_DIR="$PROJECT_ROOT/config"
DOCUMENTATION_DIR="$PROJECT_ROOT/documentation"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo -e "${BLUE}ℹ️${NC} $1"
}

echo "=== VALIDAÇÃO DE ARQUIVOS - FSx Compliance PoC ==="
echo ""

# Lista de arquivos obrigatórios (core da solução)
REQUIRED_FILES=(
    "$PROJECT_ROOT/scripts/bash/deploy-fsx-compliance-poc.sh"
    "$CLOUDFORMATION_DIR/fsx-compliance-main.yaml"
    "$CLOUDFORMATION_DIR/fsx-storage.yaml"
    "$CLOUDFORMATION_DIR/macie-processing.yaml"
    "$CLOUDFORMATION_DIR/windows-client.yaml"
    "$PROJECT_ROOT/README.md"
)

# Lista de arquivos opcionais (documentação e exemplos)
OPTIONAL_FILES=(
    "$DOCUMENTATION_DIR/fsx-macie-architecture.md"
    "$DOCUMENTATION_DIR/fsx-integration-flows.md"
    "$CONFIG_DIR/parameters-example.json"
    "$DOCUMENTATION_DIR/architecture-diagram.md"
    "$DOCUMENTATION_DIR/data-flow-diagram.md"
    "$DOCUMENTATION_DIR/fixes-applied.md"
    "$DOCUMENTATION_DIR/arn-troubleshooting.md"
    "$DOCUMENTATION_DIR/rollback-handling.md"
    "$DOCUMENTATION_DIR/readme-compliance-test.md"
)

echo "1. VERIFICANDO ARQUIVOS OBRIGATÓRIOS:"
echo ""

missing_files=0
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        success "$file"
    else
        error "$file - ARQUIVO FALTANDO!"
        missing_files=$((missing_files + 1))
    fi
done

echo ""
echo "2. VERIFICANDO ARQUIVOS OPCIONAIS:"
echo ""

optional_found=0
for file in "${OPTIONAL_FILES[@]}"; do
    if [ -f "$file" ]; then
        success "$file"
        optional_found=$((optional_found + 1))
    else
        warning "$file - arquivo opcional não encontrado"
    fi
done

echo ""
echo "3. VERIFICANDO REFERÊNCIAS NO SCRIPT DE DEPLOY:"
echo ""

# Verificar se o script referencia os arquivos corretos
if [ -f "deploy-fsx-compliance-poc.sh" ]; then
    # Extrair templates referenciados no script
    templates_in_script=$(grep -o '"[^"]*\.yaml"' deploy-fsx-compliance-poc.sh | tr -d '"' | sort | uniq)
    
    echo "Templates referenciados no script:"
    for template in $templates_in_script; do
        if [ -f "$template" ]; then
            success "$template - referência correta"
        else
            error "$template - REFERÊNCIA INCORRETA! Arquivo não existe"
            missing_files=$((missing_files + 1))
        fi
    done
    
    # Verificar se não há referências a arquivos antigos (com key-pair)
    if grep -q "windows-client-no-keypair\|deploy-no-keypair" deploy-fsx-compliance-poc.sh; then
        error "Script contém referências a arquivos antigos (com key-pair)!"
        missing_files=$((missing_files + 1))
    else
        success "Nenhuma referência a arquivos antigos encontrada"
    fi
    
else
    error "Script de deploy não encontrado!"
    missing_files=$((missing_files + 1))
fi

echo ""
echo "4. VERIFICANDO PERMISSÕES:"
echo ""

if [ -f "deploy-fsx-compliance-poc.sh" ]; then
    if [ -x "deploy-fsx-compliance-poc.sh" ]; then
        success "deploy-fsx-compliance-poc.sh - executável"
    else
        warning "deploy-fsx-compliance-poc.sh - não é executável (execute: chmod +x deploy-fsx-compliance-poc.sh)"
    fi
fi

if [ -f "validate-files.sh" ]; then
    if [ -x "validate-files.sh" ]; then
        success "validate-files.sh - executável"
    else
        warning "validate-files.sh - não é executável (execute: chmod +x validate-files.sh)"
    fi
fi

echo ""
echo "5. VERIFICANDO SINTAXE DOS TEMPLATES YAML:"
echo ""

yaml_valid=0
yaml_total=0

for yaml_file in *.yaml; do
    if [ -f "$yaml_file" ]; then
        yaml_total=$((yaml_total + 1))
        # Verificação básica de sintaxe YAML
        if python3 -c "import yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null; then
            success "$yaml_file - sintaxe YAML válida"
            yaml_valid=$((yaml_valid + 1))
        else
            # Tentar com yq se python não funcionar
            if command -v yq &> /dev/null; then
                if yq eval '.' "$yaml_file" >/dev/null 2>&1; then
                    success "$yaml_file - sintaxe YAML válida (via yq)"
                    yaml_valid=$((yaml_valid + 1))
                else
                    error "$yaml_file - SINTAXE YAML INVÁLIDA!"
                    missing_files=$((missing_files + 1))
                fi
            else
                warning "$yaml_file - não foi possível validar sintaxe (instale python3 ou yq)"
            fi
        fi
    fi
done

echo ""
echo "6. VERIFICANDO ESTRUTURA DO PROJETO:"
echo ""

# Verificar se estamos no diretório correto
if [ -f "$PROJECT_ROOT/scripts/bash/deploy-fsx-compliance-poc.sh" ] && [ -f "$PROJECT_ROOT/README.md" ]; then
    success "Estrutura do projeto correta"
else
    error "Estrutura do projeto incorreta - execute este script no diretório fsx-s3-macie"
    missing_files=$((missing_files + 1))
fi

# Verificar se não há arquivos antigos (com key-pair)
old_files=0
if [ -f "windows-client-no-keypair.yaml" ]; then
    error "Arquivo antigo encontrado: windows-client-no-keypair.yaml (deve ser removido)"
    old_files=$((old_files + 1))
fi

if [ -f "deploy-no-keypair.sh" ]; then
    error "Arquivo antigo encontrado: deploy-no-keypair.sh (deve ser removido)"
    old_files=$((old_files + 1))
fi

if [ $old_files -eq 0 ]; then
    success "Nenhum arquivo antigo encontrado"
fi

echo ""
echo "7. VERIFICANDO CONSISTÊNCIA DOS ARQUIVOS:"
echo ""

# Verificar se README menciona os arquivos corretos
if [ -f "$PROJECT_ROOT/README.md" ]; then
    if grep -q "windows-client.yaml" "$PROJECT_ROOT/README.md"; then
        success "README referencia windows-client.yaml corretamente"
    else
        warning "README pode não referenciar windows-client.yaml"
    fi
    
    if grep -q "deploy-fsx-compliance-poc.sh" "$PROJECT_ROOT/README.md"; then
        success "README referencia deploy-fsx-compliance-poc.sh corretamente"
    else
        warning "README pode não referenciar deploy-fsx-compliance-poc.sh"
    fi
fi

# Verificar se há diagramas de arquitetura
diagram_files=0
if [ -f "architecture-diagram.md" ]; then
    success "Diagrama de arquitetura principal encontrado"
    diagram_files=$((diagram_files + 1))
fi

if [ -f "data-flow-diagram.md" ]; then
    success "Diagrama de fluxo de dados encontrado"
    diagram_files=$((diagram_files + 1))
fi

if [ -f "mermaid-diagrams-only.md" ]; then
    success "Diagramas Mermaid para visualização encontrados"
    diagram_files=$((diagram_files + 1))
fi

echo ""
echo "=== RESUMO DA VALIDAÇÃO ==="
echo ""

total_required=${#REQUIRED_FILES[@]}
found_required=$((total_required - missing_files))
total_optional=${#OPTIONAL_FILES[@]}

info "📋 Arquivos obrigatórios: $found_required/$total_required"
info "📚 Arquivos opcionais: $optional_found/$total_optional"
info "📊 Diagramas de arquitetura: $diagram_files"

if [ $yaml_total -gt 0 ]; then
    info "⚙️ Templates YAML válidos: $yaml_valid/$yaml_total"
fi

if [ $missing_files -eq 0 ] && [ $old_files -eq 0 ]; then
    success "VALIDAÇÃO PASSOU! Todos os arquivos estão corretos."
    echo ""
    info "📁 Estrutura do projeto:"
    info "├── 📋 Templates CloudFormation: $yaml_total arquivos"
    info "├── 🚀 Scripts de deploy: 1 arquivo"
    info "├── 📚 Documentação: $optional_found arquivos"
    info "├── 📊 Diagramas de arquitetura: $diagram_files arquivos"
    info "└── 🔧 Ferramentas: 1 arquivo de validação"
    echo ""
    info "🎯 Recursos disponíveis:"
    info "• Solução completa de compliance FSx + Macie"
    info "• Documentação técnica detalhada"
    info "• Diagramas de arquitetura visuais"
    info "• Scripts de automação e validação"
    info "• Exemplos de uso e configuração"
    echo ""
    info "🚀 Você pode executar o deploy com segurança:"
    info "./deploy-fsx-compliance-poc.sh"
    exit 0
else
    total_issues=$((missing_files + old_files))
    error "VALIDAÇÃO FALHOU! $total_issues problema(s) encontrado(s)."
    echo ""
    if [ $missing_files -gt 0 ]; then
        error "- $missing_files arquivo(s) obrigatório(s) faltando ou com problemas"
    fi
    if [ $old_files -gt 0 ]; then
        error "- $old_files arquivo(s) antigo(s) que devem ser removidos"
    fi
    echo ""
    info "Corrija os problemas acima antes de executar o deploy."
    exit 1
fi
