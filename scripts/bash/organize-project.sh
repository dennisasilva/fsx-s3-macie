#!/bin/bash

# ============================================================================
# SCRIPT DE ORGANIZAÇÃO DO PROJETO FSx S3 Macie Compliance PoC
# ============================================================================
# Este script organiza automaticamente os arquivos do projeto em pastas
# por tipo de extensão para facilitar a navegação e manutenção
# ============================================================================

echo "🗂️  Organizando projeto FSx S3 Macie Compliance PoC..."
echo ""

# Definir diretório base
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# Criar estrutura de pastas
echo "📁 Criando estrutura de pastas..."
mkdir -p scripts/powershell
mkdir -p scripts/bash
mkdir -p cloudformation
mkdir -p documentation
mkdir -p config

# Função para mover arquivos com verificação
move_files() {
    local pattern="$1"
    local destination="$2"
    local description="$3"
    
    if ls $pattern 1> /dev/null 2>&1; then
        echo "   Movendo $description para $destination/"
        mv $pattern "$destination/"
        echo "   ✅ $description movidos"
    else
        echo "   ℹ️  Nenhum arquivo $description encontrado"
    fi
}

# Organizar arquivos por tipo
echo ""
echo "🔄 Organizando arquivos por tipo..."

# Scripts PowerShell
move_files "*.ps1" "scripts/powershell" "scripts PowerShell"

# Scripts Bash
move_files "*.sh" "scripts/bash" "scripts Bash"

# Templates CloudFormation
move_files "*.yaml" "cloudformation" "templates CloudFormation"
move_files "*.yml" "cloudformation" "templates CloudFormation"

# Documentação
move_files "*.md" "documentation" "arquivos de documentação"

# Arquivos de configuração
move_files "*.json" "config" "arquivos JSON"
move_files "*.txt" "config" "arquivos de texto"
move_files "*.config" "config" "arquivos de configuração"
move_files ".fsx-compliance-config" "config" "arquivo de configuração do projeto"

echo ""
echo "📊 Estrutura final do projeto:"
echo ""
tree -a -I '.git|node_modules' || find . -type d -name ".*" -prune -o -type f -print | sort

echo ""
echo "✅ Organização concluída!"
echo ""
echo "📋 Resumo da estrutura:"
echo "   📁 scripts/powershell/  - Scripts PowerShell (.ps1)"
echo "   📁 scripts/bash/        - Scripts Shell (.sh)"
echo "   📁 cloudformation/      - Templates CloudFormation (.yaml/.yml)"
echo "   📁 documentation/       - Documentação (.md)"
echo "   📁 config/              - Configurações (.json, .txt, .config)"
echo ""
echo "💡 Para mais informações, consulte o README.md"
