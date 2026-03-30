# =============================================================
# Imagem base: Node 22 slim vinda do ECR público da AWS
# Usamos o ECR público para evitar rate limit do Docker Hub
# =============================================================
FROM public.ecr.aws/docker/library/node:22-slim

# =============================================================
# Instala o curl — necessário para o health check da aplicação
# Limpa o cache do apt ao final para reduzir o tamanho da imagem
# =============================================================
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# =============================================================
# Define o diretório de trabalho dentro do container
# Todos os comandos seguintes serão executados a partir daqui
# =============================================================
WORKDIR /usr/src/app

# =============================================================
# Copia e instala as dependências do backend (raiz do projeto)
# Copiamos só o package.json antes do restante do código para
# aproveitar o cache do Docker — se o package.json não mudar,
# o npm install não roda de novo
# =============================================================
COPY package*.json ./
RUN npm install --loglevel=error

# =============================================================
# Copia e instala as dependências do frontend (React + Vite)
# --legacy-peer-deps resolve conflitos de versão entre pacotes
# =============================================================
COPY client/package*.json ./client/
RUN cd client && npm install --legacy-peer-deps --loglevel=error

# =============================================================
# Copia todo o restante do código fonte para dentro do container
# =============================================================
COPY . .

# =============================================================
# Faz o build do frontend com o Vite
# VITE_API_URL aponta para onde o frontend vai buscar a API
# Em produção na AWS, esse valor será substituído pelo DNS do ALB
# =============================================================
RUN cd client && VITE_API_URL=http://bia-alb-1814212738.us-east-1.elb.amazonaws.com npm run build

# =============================================================
# Remove dependências de desenvolvimento do client após o build
# Reduz o tamanho final da imagem
# =============================================================
RUN cd client && npm prune --production && rm -rf node_modules/.cache

# =============================================================
# Porta que a aplicação expõe dentro do container
# O mapeamento para a porta do host é feito no compose.yml
# =============================================================
EXPOSE 8080

# =============================================================
# Comando que inicia a aplicação quando o container sobe
# =============================================================
CMD [ "npm", "start" ]
