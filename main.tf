terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Região padrão do AWS Academy, geralmente N. Virginia
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "meu_alb" {
  name               = "meu-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.app_sg.id] # Reutilizando seu SG
  subnets            = data.aws_subnets.default.ids   # Usa as subnets públicas
}

resource "aws_lb_target_group" "meu_tg" {
  name        = "meu-target-group"
  port        = 8080 # A porta que seu BACKEND escuta
  protocol    = "HTTP"
  target_type = "ip" # Obrigatório para Fargate
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.meu_alb.arn
  port              = "80" # O usuário acessa a porta 80 (padrão web)
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.meu_tg.arn
  }
}


output "url_do_backend" {
  value = "http://${aws_lb.meu_alb.dns_name}"
}

# 2. SEGURANÇA DE REDE
# Cria o Security Group para permitir acesso à aplicação
# --- CORREÇÃO 1: Mudar o nome do Security Group ---
resource "aws_security_group" "app_sg" {
  name        = "app-task-sg-v2" # <--- MUDEI O NOME AQUI PARA EVITAR DUPLICIDADE
  description = "Permitir acesso HTTP a aplicacao"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# 3. CLUSTER ECS
resource "aws_ecs_cluster" "main" {
  name = "cluster-fullstack-lab"
}

# Definição da Task com os 3 Containers (Front + Back + DB)
resource "aws_ecs_task_definition" "app_task" {
  family                   = "locadora-fullstack-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  # Role do laboratório (ajuste se necessário para a variável data)
  # execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  # task_role_arn      = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"

  container_definitions = jsonencode([
    # ---------------------------------------------------------
    # 1. BANCO DE DADOS (Postgres)
    # ---------------------------------------------------------
    {
      name      = "locadora-db"
      image     = "postgres:15-alpine"
      essential = true
      portMappings = [
        { containerPort = 5432, hostPort = 5432 }
      ]
      environment = [
        { name = "POSTGRES_DB", value = "plocadora" },
        { name = "POSTGRES_USER", value = "plocadora_user" },
        { name = "POSTGRES_PASSWORD", value = "plocadora_pass" }
      ]
      # Nota: Em Fargate, volumes "bind" ou persistentes exigem EFS. 
      # Sem EFS, os dados do banco somem ao parar a task.
    },

    # ---------------------------------------------------------
    # 2. BACK-END (Spring Boot)
    # ---------------------------------------------------------
    {
      name      = "locadora-api"
      image     = "victorcostac/plocadora:1.0.0"
      essential = true
      portMappings = [
        { containerPort = 8080, hostPort = 8080 }
      ]
      environment = [
        { name = "SPRING_DATASOURCE_URL", value = "jdbc:postgresql://127.0.0.1:5432/plocadora" },
        { name = "SPRING_DATASOURCE_USERNAME", value = "plocadora_user" },
        { name = "SPRING_DATASOURCE_PASSWORD", value = "plocadora_pass" },
        { name = "SPRING_DATASOURCE_DRIVER_CLASS_NAME", value = "org.postgresql.Driver" },
        { name = "SPRING_JPA_DATABASE_PLATFORM", value = "org.hibernate.dialect.PostgreSQLDialect" },
        { name = "SPRING_JPA_HIBERNATE_DDL_AUTO", value = "update" },
        { name = "SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE", value = "10" }
      ]
      dependsOn = [
        { containerName = "locadora-db", condition = "START" }
      ]
    },

    # ---------------------------------------------------------
    # 3. FRONT-END
    # ---------------------------------------------------------
    # ---------------------------------------------------------
    # 3. FRONT-END
    # ---------------------------------------------------------
    {
      name      = "front-end"
      image     = "andregaros/plocadora-frontend"
      essential = true
      portMappings = [
        { containerPort = 80, hostPort = 80 }
      ]
      environment = [
        # --- A MÁGICA ACONTECE AQUI ---
        # Em vez de localhost, usamos a variável do Terraform que contém o DNS do Load Balancer.
        # O ALB escuta na porta 80 (padrão HTTP), então não precisa especificar porta na string.
        { name = "API_URL", value = "http://${aws_lb.meu_alb.dns_name}/ator" }
      ]
      dependsOn = [
        { containerName = "locadora-api", condition = "START" }
      ]
    }
  ])
}

# 5. SERVIÇO (DEPLOY)
resource "aws_ecs_service" "app_service" {
  name            = "app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Configuração de Rede
  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.app_sg.id]
    assign_public_ip = true # Requisito Obrigatório para baixar imagem
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.meu_tg.arn
    container_name   = "locadora-api"
    container_port   = 8080 # Porta do container definida no task definition
  }
}
