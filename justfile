set dotenv-load := true
set shell := ["bash", "-uc"]

# Caracteres para mensajes

INFO := "ℹ️"
SUCCESS := "✅"
WARNING := "⚠️"
ERROR := "❌"

# Muestra ayuda
default:
    @just --list

# Construir contenedor
build:
    docker compose build

clean-ca:
   docker ps -a | grep traefik | awk '{print $1}' | xargs docker stop
   docker ps -a | grep traefik | awk '{print $1}' | xargs docker rm
   docker image list | grep traefik | awk '{print $3}' | xargs docker rmi 
   if [ -f .env ]; then sed -i '/^STEP_EAB_KEYID=/d' .env; sed -i '/^STEP_EAB_HMAC=/d' .env; fi 
   rm -rf step/* letsencrypt/*

# Comprobar dependencias
check-deps:
    #!/usr/bin/env bash
    echo "{{ INFO }} Comprobando dependencias..."
    MISSING_DEPS=()
    for cmd in docker jq uuidgen openssl; do
      if ! command -v "$cmd" &> /dev/null; then
        MISSING_DEPS+=("$cmd")
      fi
    done

    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
      echo "{{ ERROR }} Faltan dependencias: ${MISSING_DEPS[*]}" >&2
      echo "Por favor, instala las dependencias necesarias e inténtalo de nuevo."
      exit 1
    fi

    echo "{{ SUCCESS }} Todas las dependencias están instaladas"

# Configurar archivo .env con valores por defecto
init-env:
    #!/usr/bin/env bash
    echo "{{ INFO }} Configurando archivo .env..."

    if [ -f .env ]; then
      echo "{{ INFO }} Archivo .env ya existe"
      # Comprobar si tiene las variables necesarias
      MISSING_VARS=()

      for var in DOCKER_STEPCA_INIT_PASSWORD STEP_CA_NAME STEP_CA_DNS STEP_CA_ADDRESS STEP_CA_ADMIN_EMAIL TRAEFIK_WEB_PORT TRAEFIK_WEBSECURE_PORT TRAEFIK_API_PORT; do
        if ! grep -q "^$var=" .env; then
          MISSING_VARS+=("$var")
        fi
      done

      if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "{{ WARNING }} Faltan variables en .env: ${MISSING_VARS[*]}"
        echo "¿Quieres añadir valores por defecto para estas variables? (s/N)"
        read -r response
        if [[ "$response" =~ ^[Ss]$ ]]; then
          for var in "${MISSING_VARS[@]}"; do
            case "$var" in
              DOCKER_STEPCA_INIT_PASSWORD)
                STEPCA_PASSWORD=$(openssl rand -base64 32)
                echo "DOCKER_STEPCA_INIT_PASSWORD=$STEPCA_PASSWORD" >> .env
                ;;
              STEP_CA_NAME)
                echo "STEP_CA_NAME=Local Development CA" >> .env
                ;;
              STEP_CA_DNS)
                echo "STEP_CA_DNS=step-ca" >> .env
                ;;
              STEP_CA_ADDRESS)
                echo "STEP_CA_ADDRESS=:9000" >> .env
                ;;
              STEP_CA_ADMIN_EMAIL)
                echo "STEP_CA_ADMIN_EMAIL=admin@local.test" >> .env
                ;;
              TRAEFIK_WEB_PORT)
                echo "TRAEFIK_WEB_PORT=80" >> .env
                ;;
              TRAEFIK_WEBSECURE_PORT)
                echo "TRAEFIK_WEBSECURE_PORT=443" >> .env
                ;;
              TRAEFIK_API_PORT)
                echo "TRAEFIK_API_PORT=8080" >> .env
                ;;
              *)
                echo "$var=default_value" >> .env
                echo "{{ WARNING }} Se añadió un valor por defecto genérico para $var"
                ;;
            esac
          done
          echo "{{ SUCCESS }} Variables añadidas a .env"
        else
          echo "{{ ERROR }} Por favor, añade las variables necesarias a .env manualmente" >&2
          exit 1
        fi
      fi
    elif [ -f .env.example ]; then
      echo "{{ INFO }} Creando .env desde .env.example..."
      cp .env.example .env
      echo "{{ SUCCESS }} Archivo .env creado desde .env.example"
    else
      echo "{{ INFO }} Creando .env con valores por defecto..."

      # Generar contraseñas seguras
      STEPCA_PASSWORD=$(openssl rand -base64 32)
      PG_PASSWORD=$(openssl rand -base64 16)

      # Crear archivo .env
      echo "# Configuración Step-CA" > .env
      echo "DOCKER_STEPCA_INIT_PASSWORD=$STEPCA_PASSWORD" >> .env
      echo "STEP_CA_NAME=Local Development CA" >> .env
      echo "STEP_CA_DNS=step-ca" >> .env
      echo "STEP_CA_ADDRESS=:9000" >> .env
      echo "STEP_CA_ADMIN_EMAIL=admin@local.test" >> .env

      echo >> .env
      echo "# Configuración Traefik" >> .env
      echo "TRAEFIK_WEB_PORT=80" >> .env
      echo "TRAEFIK_WEBSECURE_PORT=443" >> .env
      echo "TRAEFIK_API_PORT=8080" >> .env

      echo >> .env
      echo "# Configuración PostgreSQL" >> .env
      echo "POSTGRES_USER=postgres" >> .env
      echo "POSTGRES_PASSWORD=$PG_PASSWORD" >> .env

      echo >> .env
      echo "# Dominios" >> .env
      echo "ARCANE_DOMAIN=arcane.local.test" >> .env
      echo "TASKS_DOMAIN=tasks.local.test" >> .env

      echo "{{ SUCCESS }} Archivo .env creado con valores por defecto"
    fi

# Inicializar step-ca
init-stepca:
    #!/usr/bin/env bash
    echo "{{ INFO }} Inicializando Step-CA..."

    # Limpiar directorio step/config si está corrupto
    if [ -d "step/config" ] && [ ! -f "step/config/ca.json" ]; then
      echo "{{ WARNING }} Directorio step/config existe pero sin ca.json, limpiando..."
      rm -rf step/config
    fi

    # Ejecutar script de inicialización
    if [ -f "scripts/init_stepca.sh" ]; then
      bash scripts/init_stepca.sh
      echo "{{ SUCCESS }} Step-CA inicializado correctamente"
    else
      echo "{{ ERROR }} No se encuentra el script scripts/init_stepca.sh" >&2
      exit 1
    fi

# Verificar step-ca
verify-stepca:
    #!/usr/bin/env bash
    echo "{{ INFO }} Verificando inicialización de Step-CA..."

    if [ ! -f "step/config/ca.json" ]; then
      echo "{{ ERROR }} No se encontró el archivo step/config/ca.json después de la inicialización" >&2
      exit 1
    fi

    # Verificar que .env contiene STEP_EAB_KEYID y STEP_EAB_HMAC
    if ! grep -q "^STEP_EAB_KEYID=" .env || ! grep -q "^STEP_EAB_HMAC=" .env; then
      echo "{{ ERROR }} No se encontraron las credenciales EAB en .env" >&2
      exit 1
    fi

    echo "{{ SUCCESS }} Step-CA inicializado y verificado correctamente"

# Arrancar contenedores por defecto (todos sin perfil)
up:
    if [ ! -f .env ]; then cp .env.example .env; fi
    docker compose up -d

# Arrancar contenedores con perfiles adicionales
up-profiles PROFILES:
    if [ ! -f .env ]; then cp .env.example .env; fi
    docker compose --profile {{ PROFILES }} up -d

# Parar todos los contenedores
down:
    docker compose down

# Arrancar step-ca primero y luego el resto de servicios
up-stepca-first:
    #!/usr/bin/env bash
    echo "{{ INFO }} Levantando step-ca primero..."

    # Primero levantar step-ca
    docker compose up -d step-ca

    # Esperar a que step-ca esté listo
    echo "{{ INFO }} Esperando a que step-ca esté listo..."
    for i in $(seq 1 30); do
      if docker compose exec step-ca sh -c 'pgrep step-ca >/dev/null'; then
        break
      fi
      echo -n "."
      sleep 1
      if [ "$i" -eq 30 ]; then
        echo "{{ ERROR }} Timeout esperando a que step-ca esté listo" >&2
        exit 1
      fi
    done
    echo

    # Levantar el resto del stack
    docker compose up -d
    echo "{{ SUCCESS }} Stack levantado correctamente"

# Mostrar información del stack
show-info:
    #!/usr/bin/env bash
    echo "{{ INFO }} === Stack local inicializado correctamente ==="
    echo
    echo "Puedes acceder a los siguientes servicios:"
    echo

    # Extraer dominios de .env
    ARCANE_DOMAIN=$(grep "^ARCANE_DOMAIN=" .env | cut -d= -f2)
    TASKS_DOMAIN=$(grep "^TASKS_DOMAIN=" .env | cut -d= -f2)

    echo "- Traefik Dashboard: http://localhost:$(grep "^TRAEFIK_API_PORT=" .env | cut -d= -f2)"
    echo "- Arcane: https://$ARCANE_DOMAIN"
    echo "- Kanban Tasks: https://$TASKS_DOMAIN"
    echo
    echo "Para que los dominios funcionen, añade estas líneas a /etc/hosts:"
    echo "127.0.0.1 $ARCANE_DOMAIN"
    echo "127.0.0.1 $TASKS_DOMAIN"
    echo

# Reconstrucción del stack
restart:
    just down
    just build
    just up

# Reconstrucción del stack completo
restart-profiles PROFILES:
    docker compose --profile {{ PROFILES }} down
    just build
    just up-profiles {{ PROFILES }}

# Setup del stack base
setup:
    #!/usr/bin/env bash
    echo "=========================================="
    echo "🚀 Iniciando setup de stack local con Step-CA"
    echo "=========================================="

    just check-deps
    just down
    just init-env
    just init-stepca
    just verify-stepca
    just up-stepca-first
    just show-info

    echo "=========================================="
    echo "🎉 ¡Setup completado con éxito!"
    echo "=========================================="
