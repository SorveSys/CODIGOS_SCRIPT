#!/bin/bash
# ==============================================================================
# Deploy do Coletor SorveSys (Python + Java) em UMA EC2 monitorada.
#
# Rode este script em CADA servidor que deve ser monitorado. Cada EC2 se
# identifica pelo IP dela na tabela 'servidor' (cadastrada pelo Gestor no site),
# então o mesmo script serve para os 3 tipos (transito, pagamento, auditoria).
#
# Sobem dois containers, para que cada coletor reinicie sozinho se cair:
#   sorvesys-captura-py    -> captura.py  (CPU, RAM, disco, temperatura)
#   sorvesys-captura-java  -> coletor.jar (rede)
#
# Uso:
#   chmod +x script_coleta.sh
#   sudo ./script_coleta.sh
#
# Variáveis opcionais (todas têm padrão):
#   DB_HOST       IP do banco. Se as duas EC2 estão na mesma VPC, use o IP PRIVADO.
#   DB_USER       usuário do banco              (padrão: agente_pedagio)
#   DB_PASSWORD   senha; se não vier, o script pergunta (não fica salva no script)
#   DB_NAME       base de dados                 (padrão: sorvesys_db)
#   HOST_IP       IP desta máquina cadastrado no site (padrão: detectado)
#   PULAR_GIT=1   não clona o GitHub; usa captura.py e coletor.jar que você já
#                 copiou para /opt/sorvesys-captura (bom para testar antes de dar push)
#
# Exemplo:  sudo DB_HOST=10.0.1.25 ./script_coleta.sh
# ==============================================================================

REPO_CAPTURA="https://github.com/SorveSys/CODIGOS_SCRIPT.git"
PASTA_CAPTURA="/opt/sorvesys-captura"
PASTA_CONFIG="/etc/sorvesys"
ARQUIVO_ENV="$PASTA_CONFIG/captura.env"
IMAGEM="sorvesys-captura:2.0"

DB_HOST="${DB_HOST:-177.92.67.154}"
DB_USER="${DB_USER:-agente_pedagio}"
DB_NAME="${DB_NAME:-sorvesys_db}"
DB_PORT=3306

falhar() {
    echo "[ERRO] $1"
    exit 1
}

# --- Permissão root -----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    falhar "Execute este script com sudo."
fi

# --- Senha do banco: variável de ambiente ou pergunta (sem eco) -----------------
if [ -z "${DB_PASSWORD:-}" ]; then
    if [ -t 0 ]; then
        read -r -s -p "Senha do usuário '$DB_USER' no banco: " DB_PASSWORD
        echo ""
    fi
    [ -n "${DB_PASSWORD:-}" ] || falhar "Defina DB_PASSWORD (ex.: sudo DB_PASSWORD='...' ./script_coleta.sh)."
fi

echo "🚀 [1/5] Instalando dependências base (git, docker)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y git docker.io curl iproute2 >/dev/null 2>&1 || falhar "Falha ao instalar pacotes (apt)."
systemctl enable --now docker >/dev/null 2>&1 || falhar "Não consegui iniciar o Docker."

echo "📥 [2/5] Obtendo o código de captura..."
if [ "${PULAR_GIT:-0}" = "1" ]; then
    # Modo teste: usa os arquivos que você mesmo copiou para a pasta (scp), sem tocar no GitHub
    [ -d "$PASTA_CAPTURA" ] || falhar "PULAR_GIT=1, mas $PASTA_CAPTURA não existe. Copie captura.py e coletor.jar para lá."
    echo "   PULAR_GIT=1: usando os arquivos já presentes em $PASTA_CAPTURA (sem git)."
elif [ -d "$PASTA_CAPTURA/.git" ]; then
    git -C "$PASTA_CAPTURA" pull || falhar "git pull falhou."
else
    rm -rf "$PASTA_CAPTURA"
    git clone "$REPO_CAPTURA" "$PASTA_CAPTURA" || falhar "git clone falhou ($REPO_CAPTURA)."
fi

cd "$PASTA_CAPTURA" || falhar "Pasta $PASTA_CAPTURA não existe."

for arquivo in captura.py coletor.jar; do
    [ -f "$arquivo" ] || falhar "'$arquivo' não está na raiz do repositório $REPO_CAPTURA."
done

# requirements.txt padrão caso o repositório não tenha um
if [ ! -f "requirements.txt" ]; then
cat > requirements.txt << 'EOF'
psutil==7.2.2
mysql-connector-python==26.7.0
python-dotenv==1.0.1
rich==15.0.0
speedtest-cli==2.1.3
EOF
fi

echo "🔎 [3/5] Descobrindo o IP desta máquina e testando o banco..."
if [ -z "${HOST_IP:-}" ]; then
    # IP de origem que esta máquina usa para chegar ao banco (em EC2 = IP privado)
    DB_IP=$(getent ahostsv4 "$DB_HOST" 2>/dev/null | awk '{print $1; exit}')
    DB_IP="${DB_IP:-$DB_HOST}"
    HOST_IP=$(ip -4 route get "$DB_IP" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    [ -n "$HOST_IP" ] || HOST_IP=$(hostname -I | awk '{print $1}')
fi
[ -n "$HOST_IP" ] || falhar "Não consegui descobrir o IP da máquina. Rode com HOST_IP=<ip>."

echo "   IP desta máquina (HOST_IP): $HOST_IP"
echo "   Banco: $DB_HOST:$DB_PORT (usuário $DB_USER, base $DB_NAME)"

if timeout 5 bash -c "exec 3<>/dev/tcp/$DB_HOST/$DB_PORT" 2>/dev/null; then
    echo "   ✅ Porta $DB_PORT do banco acessível."
else
    echo "   ⚠️  Não consegui abrir $DB_HOST:$DB_PORT. Verifique o Security Group do banco"
    echo "      (entrada TCP 3306 liberada para este servidor) e se o IP está correto."
    echo "      Vou continuar, mas os coletores vão ficar reiniciando até o banco responder."
fi

# Credenciais em arquivo só do root, e não na linha de comando (visível em 'docker inspect'/'ps')
mkdir -p "$PASTA_CONFIG"
umask 077
cat > "$ARQUIVO_ENV" << EOF
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_USER=$DB_USER
DB_PASS=$DB_PASSWORD
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
HOST_IP=$HOST_IP
PYTHONUNBUFFERED=1
EOF
chmod 600 "$ARQUIVO_ENV"
umask 022

echo "🐳 [4/5] Gerando o Dockerfile e construindo a imagem $IMAGEM..."
cat > Dockerfile.captura << 'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# O coletor.jar é compilado para Java 17 (o default-jdk do Ubuntu 22.04 é o 11 e não roda)
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jre-headless \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip3 install --no-cache-dir -r requirements.txt

COPY captura.py /app/captura.py
COPY coletor.jar /app/coletor.jar
EOF

docker build -t "$IMAGEM" -f Dockerfile.captura . || falhar "docker build falhou."

echo "▶️  [5/5] Iniciando os containers..."
# remove o container único da versão anterior deste script e os atuais
docker rm -f sorvesys-captura sorvesys-captura-py sorvesys-captura-java >/dev/null 2>&1

docker run -d --name sorvesys-captura-py \
    --net=host --restart unless-stopped \
    --env-file "$ARQUIVO_ENV" \
    "$IMAGEM" python3 -u captura.py || falhar "Não consegui iniciar o container Python."

docker run -d --name sorvesys-captura-java \
    --net=host --restart unless-stopped \
    --env-file "$ARQUIVO_ENV" \
    "$IMAGEM" java -jar coletor.jar || falhar "Não consegui iniciar o container Java."

sleep 8

echo ""
echo "======================================================================"
echo " Coletores implantados."
echo ""
echo " IP desta máquina: $HOST_IP"
echo " >> O Gestor precisa cadastrar este servidor no site com ESTE IP. <<"
echo "    Enquanto não estiver cadastrado, os coletores só avisam e aguardam"
echo "    (o container Python reinicia a cada tentativa, é esperado)."
echo ""
echo " Acompanhar:"
echo "   sudo docker logs -f sorvesys-captura-py"
echo "   sudo docker logs -f sorvesys-captura-java"
echo "======================================================================"
echo ""
docker ps --filter "name=sorvesys-captura" --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "--- últimas linhas: python ---"
docker logs --tail 5 sorvesys-captura-py 2>&1
echo "--- últimas linhas: java ---"
docker logs --tail 5 sorvesys-captura-java 2>&1
